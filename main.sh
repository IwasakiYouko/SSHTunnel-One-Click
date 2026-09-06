#!/bin/sh
# SSHT_MANAGED_SCRIPT_V1 — standalone shell bootstrap + Python standard library.
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 SSHTunnel-One-Click contributors
# 允许商用、修改、二次开发、闭源使用和再分发。
# 复制或分发全部或实质部分时，须保留版权和许可声明；完整条款见 LICENSE。
#
# MIT License
#
# Copyright (c) 2026 SSHTunnel-One-Click contributors
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
set -eu
SSHT_SEARCH_PATH=${PATH:-/usr/bin:/bin}
export SSHT_SEARCH_PATH
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077
if [ "${1:-}" = "--help" ]; then
    printf '%s\n' '用法：sh main.sh [--light] [--no-update | --update]；安装后 ssht' '支持 Alpine 3.18+/OpenRC、Debian 9+/systemd、Ubuntu 18.04+/systemd。需要 root 和交互终端。' '小内存/小硬盘自动采用轻量模式；--light 强制开启。依赖齐全时轻量模式不自动更新。' '--no-update 跳过启动包操作；--update 强制检查更新。'
    exit 0
fi
[ "$(id -u)" = 0 ] || { echo '请使用 root：sudo sh main.sh' >&2; exit 1; }
if [ ! -t 0 ] || [ ! -t 1 ]; then
    echo '请先下载为文件，再在交互终端运行。' >&2; exit 1
fi
[ -r /etc/os-release ] || { echo '缺少 /etc/os-release' >&2; exit 1; }
# shellcheck disable=SC1091
. /etc/os-release
case "$ID" in
    alpine)
        if [ ! -d /run/openrc ] || ! command -v rc-service >/dev/null; then
            echo '需要正在运行的 OpenRC。'; exit 1
        fi ;;
    debian|ubuntu) [ -d /run/systemd/system ] || { echo '需要正在运行的 systemd。'; exit 1; } ;;
    *) echo "不支持系统：$ID"; exit 1 ;;
esac
# Bootstrap refuses upgrades of already installed dependencies, too.
if [ ! -x /usr/bin/python3 ]; then
    case " $* " in *' --no-update '*) echo '离线维护需要已安装 python3。'; exit 1 ;; esac
    export LC_ALL=C
    ssht_boot_tmp=$(mktemp -d /var/cache/ssht-bootstrap.XXXXXX)
    trap 'rm -rf "$ssht_boot_tmp"' EXIT HUP INT TERM
    if [ "$ID" = alpine ]; then
        apk update
        apk add --simulate python3 >"$ssht_boot_tmp/plan" 2>&1
        cat "$ssht_boot_tmp/plan"
        if awk '/Upgrading|Downgrading|Purging|Reinstalling/ {bad=1} END {exit !bad}' "$ssht_boot_tmp/plan"; then
            echo '安装 Python 需要变更已安装包，已停止。请先处理依赖。'; exit 1
        fi
        apk add python3
    else
        mkdir -p "$ssht_boot_tmp/lists/partial" "$ssht_boot_tmp/archives/partial"
        ssht_apt() {
            apt-get -o "Dir::State::lists=$ssht_boot_tmp/lists" \
                -o "Dir::Cache::archives=$ssht_boot_tmp/archives" \
                -o 'Dir::Cache::pkgcache=' -o 'Dir::Cache::srcpkgcache=' \
                -o Acquire::Languages=none -o Acquire::GzipIndexes=true "$@"
        }
        ssht_apt update -o APT::Update::Error-Mode=any
        ssht_apt -s --no-install-recommends install python3 >"$ssht_boot_tmp/plan"
        cat "$ssht_boot_tmp/plan"
        if awk '/^Remv / || /^Inst [^ ]+ \[/ {bad=1} END {exit !bad}' "$ssht_boot_tmp/plan"; then
            echo '安装 Python 需要变更已安装包，已停止。请先处理依赖。'; exit 1
        fi
        DEBIAN_FRONTEND=noninteractive ssht_apt -y --no-remove --no-install-recommends install python3
    fi
    rm -rf "$ssht_boot_tmp"
    trap - EXIT HUP INT TERM
fi
/usr/bin/python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 5) else 1)' || {
    echo '需要 Python 3.5 或更高版本。' >&2; exit 1
}
export PYTHONIOENCODING=utf-8 PYTHONDONTWRITEBYTECODE=1
exec /usr/bin/python3 - "$0" "$@" <<'SSHT_PYTHON'
import base64
import copy
from collections import OrderedDict
import fcntl
import getpass
import grp
import ipaddress
import json
import os
from pathlib import Path as NativePath
import pwd
import re
import shlex
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
import unicodedata


class Path(type(NativePath())):
    # Python 3.5 does not coerce Path arguments; minimal systems may use locale C.
    def read_text(self, encoding='utf-8', errors=None):
        return super().read_text(encoding=encoding, errors=errors)

    def write_text(self, data, encoding='utf-8', errors=None):
        return super().write_text(data, encoding=encoding, errors=errors)

    def symlink_to(self, target, target_is_directory=False):
        return super().symlink_to(str(target), target_is_directory)

    def resolve(self):
        return Path(os.path.realpath(str(self)))

VERSION = '1.2.0'
MARKER = 'SSHT_MANAGED_SCRIPT_V1'
ETC = Path('/etc/ssht')
DATA = Path('/var/lib/ssht')
LOG = Path('/var/log/ssht')
SCRIPT = Path('/usr/local/lib/ssht/main.sh')
GLOBAL = ETC / 'settings.json'
GROUP = 'ssht-tunnel'
MAIN_CONFIG = Path('/etc/ssh/sshd_config')
BEGIN = '# BEGIN SSHT MANAGED TUNNEL GROUP\n'
END = '# END SSHT MANAGED TUNNEL GROUP\n'
OS_ID = ''
TTY = None
LOCK = None
LIGHT = False
SSHD_OPTIONS = None


def resource_limits():
    """Use both LXC's meminfo and visible cgroup limits; never alter the host."""
    limits = []
    try:
        match = re.search(r'^MemTotal:\s+(\d+)', Path('/proc/meminfo').read_text(), re.M)
        if match:
            limits.append(int(match.group(1)) * 1024)
    except OSError:
        pass
    paths = [Path('/sys/fs/cgroup/memory.max'),
             Path('/sys/fs/cgroup/memory/memory.limit_in_bytes')]
    try:
        for line in Path('/proc/self/cgroup').read_text().splitlines():
            _, controllers, location = line.split(':', 2)
            if not controllers or 'memory' in controllers.split(','):
                root = Path('/sys/fs/cgroup') if not controllers else Path('/sys/fs/cgroup/memory')
                filename = 'memory.max' if not controllers else 'memory.limit_in_bytes'
                location = root / location.lstrip('/')
                for parent in (location,) + tuple(location.parents):
                    if parent == root or root in parent.parents:
                        paths.append(parent / filename)
    except (OSError, ValueError):
        pass
    for path in paths:
        try:
            value = int(path.read_text().strip())
            if value > 0:
                limits.append(value)
        except (OSError, ValueError):
            pass
    disk = os.statvfs('/var')
    return min(limits) if limits else None, disk.f_blocks * disk.f_frsize


def unlink_if_exists(path):
    try:
        path.unlink()
    except FileNotFoundError:
        pass


def random_password():
    return base64.urlsafe_b64encode(os.urandom(48)).decode('ascii')


def sshd_supports(option):
    global SSHD_OPTIONS
    if SSHD_OPTIONS is None:
        # -T expands defaults without binding a socket or starting a daemon.
        result = run(['/usr/sbin/sshd', '-T', '-f', '/dev/null'], capture=True)
        SSHD_OPTIONS = set(line.split()[0].lower() for line in result.stdout.splitlines() if line.strip())
    return option.lower() in SSHD_OPTIONS


class Error(Exception):
    pass


def run(args, check=True, capture=False, input=None):
    """Never use a shell; never include input (possibly a password) in errors."""
    env = dict(os.environ, LC_ALL='C', DEBIAN_FRONTEND='noninteractive')
    raw_input = input.encode('utf-8') if isinstance(input, str) else input
    p = subprocess.run([str(x) for x in args], input=raw_input,
                       stdout=subprocess.PIPE if capture else None,
                       stderr=subprocess.STDOUT if capture else None, env=env)
    if capture:
        p.stdout = p.stdout.decode('utf-8', errors='replace')
    if check and p.returncode:
        raise Error('命令失败：' + ' '.join(shlex.quote(str(x)) for x in args) +
                    ('\n' + (p.stdout or '') if capture else ''))
    return p


def paint(text, tone='normal'):
    if tone == 'normal' or not sys.stdout.isatty() or os.environ.get('TERM', '') == 'dumb' or 'NO_COLOR' in os.environ:
        return str(text)
    colors = {'normal': '0', 'title': '1;36', 'muted': '90', 'accent': '36',
              'good': '1;32', 'warning': '1;33', 'danger': '1;31'}
    return '\033[' + colors[tone] + 'm' + str(text) + '\033[0m'


def cell_width(text):
    return sum(0 if unicodedata.combining(c) else
               (2 if unicodedata.east_asian_width(c) in ('W', 'F') else 1) for c in text)


def ui_width():
    return max(16, min(76, shutil.get_terminal_size((80, 24)).columns - 2))


def ui_wrap(text, width):
    # Count Chinese characters by terminal cells; keep long labels readable on phones.
    for paragraph in str(text).split('\n'):
        line, used = '', 0
        for char in paragraph:
            size = cell_width(char)
            if line and used + size > width:
                carry = ''
                if len(line) > 1 and (char in '，。；：、！？）】》」』,.!?;:)]}' or line[-1] in '（【《「『([{'):
                    cut = len(line) - 1
                    while cut > 0 and unicodedata.combining(line[cut]):
                        cut -= 1
                    line, carry = line[:cut], line[cut:]
                yield line.rstrip()
                line, used = carry, cell_width(carry)
            line += char
            used += size
        yield line.rstrip()


def ui_text(text, tone='normal', indent=2):
    for line in ui_wrap(text, max(1, ui_width() - indent)):
        print(' ' * indent + paint(line, tone))


def ui_rule():
    print('  ' + paint('─' * (ui_width() - 2), 'muted'))


def menu_banner(system_name):
    print()
    ui_rule()
    ui_text('sshtunnel 一键脚本', 'title')
    ui_text('v{}  /  {}'.format(VERSION, '轻量模式' if LIGHT else '标准模式'), 'good')
    ui_text(system_name, 'muted')
    ui_rule()
    ui_text('输入编号；回车使用默认项。', 'muted')
    ui_text('q 取消 · Ctrl+C 返回主菜单', 'muted')


def ask(label, default=None):
    ui_text(label)
    suffix = '默认 ' + paint(str(default), 'good') + '  ' if default is not None else ''
    print('  ' + suffix + paint('> ', 'accent'), end='', flush=True)
    line = TTY.readline()
    if not line:
        raise EOFError()
    value = line.strip()
    if value.lower() == 'q':
        raise KeyboardInterrupt()
    return value if value else (str(default) if default is not None else '')


def yes(label, default=False):
    while True:
        value = ask(label + ' (y/n)', 'y' if default else 'n').lower()
        if value in ('y', 'yes', 'n', 'no'):
            return value in ('y', 'yes')
        print('请输入 y 或 n。')


def number(label, default, lo=1, hi=65535):
    while True:
        value = ask(label, default)
        if re.fullmatch(r'[0-9]+', value) and lo <= int(value) <= hi:
            return int(value)
        print('请输入 {}～{} 的整数。'.format(lo, hi))


def choose(label, options, default='1', sections=None, danger=()):
    print()
    ui_rule()
    ui_text(label, 'title')
    if sections is None:
        keys = sorted(options, key=lambda k: (k == '0', 0 if k.isdigit() else 1,
                                               int(k) if k.isdigit() else k))
        sections = [('', keys)]
    for heading, keys in sections:
        print()
        if heading:
            ui_text(heading, 'muted')
        for key in keys:
            prefix = '  [{}]  '.format(key)
            tone = 'danger' if key in danger else ('good' if key == default else 'accent')
            text = options[key] + ('  (默认)' if key == default else '')
            for i, line in enumerate(ui_wrap(text, max(1, ui_width() - len(prefix)))):
                lead = paint(prefix, tone) if i == 0 else ' ' * len(prefix)
                print(lead + paint(line, tone if key in danger or key == default else 'normal'))
    print()
    ui_rule()
    while True:
        value = ask('输入编号（q 取消）', default)
        if value in options:
            return value
        ui_text('没有这个选项，请输入菜单中的编号。', 'warning')


def safe_dir(path, mode=0o700):
    path = Path(path)
    # Reject symlinks and any writable/non-root ancestor, including /tmp.
    for part in reversed((path,) + tuple(path.parents)):
        if part.is_symlink():
            raise Error('拒绝符号链接目录：' + str(part))
        if part.exists():
            s = part.stat()
            if not stat.S_ISDIR(s.st_mode) or s.st_uid != 0 or s.st_mode & 0o022:
                raise Error('目录必须归 root 所有且不能被组/其他用户写入：' + str(part))
        else:
            part.mkdir(mode=mode)
    os.chmod(str(path), mode)


def atomic(path, content, mode=0o600):
    path = Path(path)
    if path.is_symlink():
        raise Error('拒绝覆盖符号链接：' + str(path))
    raw = content.encode() if isinstance(content, str) else content
    fd, name = tempfile.mkstemp(prefix='.ssht-', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'wb') as f:
            os.fchmod(f.fileno(), mode)
            f.write(raw)
            f.flush()
            os.fsync(f.fileno())
        os.replace(name, str(path))
    finally:
        if os.path.exists(name):
            os.unlink(name)


def save_json(path, value):
    atomic(path, json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def load_json(path):
    return json.loads(Path(path).read_text())


def valid_name(name):
    # Keep f2b-ssht-<name> within legacy iptables' 29-character chain limit.
    return bool(re.fullmatch(r'[a-z][a-z0-9_-]{0,19}', name)) and name != 'root'


def profile_path(name):
    if not valid_name(name):
        raise Error('非法账户名')
    return ETC / 'users' / (name + '.json')


def profiles():
    return [load_json(p) for p in sorted((ETC / 'users').glob('*.json'))]


def pkg_installed(name):
    if OS_ID == 'alpine':
        return run(['apk', 'info', '-e', name], check=False, capture=True).returncode == 0
    p = run(['dpkg-query', '-W', '-f=${Status}', name], check=False, capture=True)
    return p.returncode == 0 and p.stdout.strip() == 'install ok installed'


def package_names(with_f2b=False):
    if OS_ID == 'alpine':
        # openrc triggers the distribution's install_if splits on newer Alpine;
        # 3.18 keeps the service script in openssh-server-common itself.
        names = ['python3', 'openssh-server', 'openssh-server-common',
                 'openssh-keygen', 'openrc', 'shadow', 'iptables', 'ip6tables']
        if with_f2b or pkg_installed('fail2ban'):
            names += ['fail2ban', 'iptables', 'ip6tables']
    else:
        names = ['python3', 'openssh-server', 'openssh-client', 'passwd', 'mawk', 'iptables']
        if with_f2b or pkg_installed('fail2ban'):
            names += ['fail2ban', 'iptables']
    # Distribution split packages are part of the OpenSSH/Python runtime. Keep them
    # together, otherwise strict version guards would block nearly every SSH update.
    if OS_ID == 'alpine':
        installed = re.findall(r'^P:(.+)$', Path('/lib/apk/db/installed').read_text(), re.M)
    else:
        data = run(['dpkg-query', '-W', '-f=${binary:Package} ${Status}\n'], capture=True).stdout
        installed = [line.split()[0].split(':')[0] for line in data.splitlines()
                     if line.endswith(' install ok installed')]
    py = '{}.{}'.format(sys.version_info.major, sys.version_info.minor)
    runtime = {'python3-minimal', 'libpython3-stdlib', 'python' + py, 'python' + py + '-minimal',
               'libpython' + py + '-minimal', 'libpython' + py + '-stdlib', 'libpython' + py}
    if OS_ID == 'alpine':
        runtime.update(n for n in installed if n in ('pyc', 'python3-pyc') or n.startswith('python3-pycache-'))
    names += [n for n in installed if n.startswith('openssh-') or n in runtime]
    return sorted(set(names))


def check_package_plan(output, allowed, alpine=False):
    """Refuse removal/downgrades and upgrades outside the explicit allowlist."""
    for line in output.splitlines():
        if alpine:
            if re.search(r'\b(Purging|Downgrading|Removing)\b', line):
                raise Error('包计划含删除/降级，拒绝执行：' + line)
            m = re.search(r'\b(?:Upgrading|Reinstalling)\s+(\S+)', line)
            if m and m.group(1) not in allowed:
                raise Error('需要升级无关包，拒绝执行：' + line)
        else:
            if line.startswith('Remv '):
                raise Error('包计划含删除，拒绝执行：' + line)
            m = re.match(r'Inst (\S+) \[([^]]+)\] \((\S+)', line)
            if m:
                if m.group(1).split(':')[0] not in allowed:
                    raise Error('需要升级无关包，拒绝执行：' + line)
                if run(['dpkg', '--compare-versions', m.group(3), 'lt', m.group(2)],
                       check=False, capture=True).returncode == 0:
                    raise Error('包计划含降级，拒绝执行：' + line)


def update_packages(with_f2b=False):
    names = package_names(with_f2b)
    print('正在刷新软件源索引。本次只安装或更新：' + ', '.join(names))
    print('可以安装必要的新依赖。如果还要升级无关的已安装包，会停止操作。')
    if OS_ID == 'alpine':
        run(['apk', 'update'])
        virtual = '.ssht-update-guard'
        if pkg_installed(virtual):
            raise Error('发现上次遗留的 APK 版本保护包；请先检查 apk del --simulate ' + virtual +
                        '，确认只删除保护包后手动移除，再重试。')
        # Version locks prevent the real solver from changing unrelated installed packages.
        installed = {}
        db = Path('/lib/apk/db/installed').read_text()
        for block in db.split('\n\n'):
            fields = dict(line.split(':', 1) for line in block.splitlines() if ':' in line)
            if 'P' in fields and 'V' in fields:
                installed[fields['P']] = fields['V']
        pins = [n + '=' + v for n, v in installed.items() if n not in names]
        # --virtual keeps dependency pins out of the permanent world file; delete it afterwards.
        guard = ['apk', 'add', '--virtual', virtual] + pins
        plan = run(guard[:2] + ['--simulate'] + guard[2:], capture=True).stdout
        check_package_plan(plan, names, True)
        run(guard)
        try:
            args = ['apk', 'add', '--upgrade'] + names
            plan = run(args[:2] + ['--simulate'] + args[2:], capture=True).stdout
            print(plan)
            check_package_plan(plan, names, True)
            run(args)
        finally:
            cleanup = run(['apk', 'del', '--simulate', virtual], capture=True).stdout
            for line in cleanup.splitlines():
                m = re.search(r'\b(?:Purging|Removing)\s+(\S+)', line)
                if m and m.group(1) != virtual:
                    raise Error('移除 APK 保护包会删除其他包，保留保护包供人工检查：' + line)
            run(['apk', 'del', virtual])
    else:
        state = run(['dpkg-query', '-W', '-f=${binary:Package}\t${Version}\t${Status}\n'], capture=True).stdout
        pins = []
        for line in state.splitlines():
            n, v, status = line.split('\t', 2)
            if status == 'install ok installed' and n.split(':')[0] not in names:
                pins.append('Package: {}\nPin: version {}\nPin-Priority: 1001\n'.format(n, v))
        with tempfile.TemporaryDirectory(prefix='apt-', dir=str(ETC)) as td:
            # Keep only this operation's lists/archives, on disk rather than /run.
            for sub in ('lists/partial', 'archives/partial'):
                (Path(td) / sub).mkdir(parents=True)
            apt = ['apt-get', '-o', 'Dir::State::lists=' + td + '/lists',
                   '-o', 'Dir::Cache::archives=' + td + '/archives',
                   '-o', 'Dir::Cache::pkgcache=', '-o', 'Dir::Cache::srcpkgcache=',
                   '-o', 'Acquire::Languages=none', '-o', 'Acquire::GzipIndexes=true']
            run(apt + ['update', '-o', 'APT::Update::Error-Mode=any'])
            pref = Path(td) / 'preferences'
            original = Path('/etc/apt/preferences')
            atomic(pref, (original.read_text() if original.exists() else '') + '\n' + '\n'.join(pins))
            args = apt + ['-o', 'Dir::Etc::preferences=' + str(pref),
                    '-o', 'Dpkg::Options::=--force-confold', '--no-remove',
                    '--no-install-recommends', 'install'] + names
            plan = run(args[:1] + ['-s'] + args[1:], capture=True).stdout
            print(plan)
            check_package_plan(plan, names)
            run(args[:1] + ['-y'] + args[1:])
    print('软件包安装或更新完成。请从维护菜单重启已有隧道，让它使用新版程序。')


def package_status():
    for name in package_names():
        print('\n--- ' + name + ' ---')
        if OS_ID == 'alpine':
            run(['apk', 'policy', name], check=False)
        else:
            run(['apt-cache', 'policy', name], check=False)
    print('Installed/已安装 与 Candidate/仓库候选版本；版本以当前配置的软件源为准。')


def registration(source):
    settings = load_json(GLOBAL) if GLOBAL.exists() else {'command': 'ssht'}
    name = settings['command']
    while True:
        if not re.fullmatch(r'[a-z][a-z0-9_-]{1,31}', name):
            print('命令名需要 2～32 位小写字母、数字、下划线或连字符。')
        else:
            target = Path('/usr/local/bin') / name
            collisions = []
            for d in (os.environ['PATH'] + ':' + os.environ.get('SSHT_SEARCH_PATH', '')).split(':'):
                if not d:
                    continue
                p = Path(d) / name
                if p.exists() or p.is_symlink():
                    if not (p == target and p.is_symlink() and os.readlink(str(p)) == str(SCRIPT)):
                        collisions.append(str(p))
            builtin = run(['/bin/sh', '-c', 'command -v ' + name], capture=True, check=False)
            if builtin.returncode == 0 and not builtin.stdout.strip().startswith('/'):
                collisions.append(builtin.stdout.strip())
            if not collisions:
                break
            print('这个命令名已被占用：' + ', '.join(sorted(set(collisions))))
        name = ask('请换一个命令名')
    safe_dir(SCRIPT.parent)
    safe_dir('/usr/local/bin', 0o755)
    if source.resolve() != SCRIPT.resolve():
        if SCRIPT.exists() and MARKER not in SCRIPT.read_text()[:200]:
            raise Error('安装路径已有不属于本脚本的文件：' + str(SCRIPT))
        atomic(SCRIPT, source.read_bytes(), 0o700)
    target = Path('/usr/local/bin') / name
    if not target.is_symlink():
        target.symlink_to(SCRIPT)
    settings['command'] = name
    save_json(GLOBAL, settings)
    print('管理命令已检查：' + name)


def service(name, operation, check=True):
    if OS_ID == 'alpine':
        if operation == 'enable':
            return run(['rc-update', 'add', name, 'default'], check=check, capture=True)
        if operation == 'disable':
            return run(['rc-update', 'del', name, 'default'], check=check, capture=True)
        return run(['rc-service', name, operation], check=check, capture=True)
    return run(['systemctl', operation, name], check=check, capture=True)


def active(name):
    return service(name, 'status' if OS_ID == 'alpine' else 'is-active', False).returncode == 0


def reload_main():
    if OS_ID == 'alpine':
        if active('sshd'):
            service('sshd', 'reload')
    else:
        for name in ('ssh', 'sshd'):
            if active(name):
                service(name, 'reload')
                break


def deny_group_config(text):
    if text.count(BEGIN) != text.count(END) or text.count(BEGIN) > 1:
        raise Error('系统 SSH 中的 SSHT 管理区块损坏，请先检查。')
    text = re.sub(re.escape(BEGIN) + '.*?' + re.escape(END), '', text, flags=re.S)
    return BEGIN + 'DenyGroups ' + GROUP + '\n' + END + text


def ensure_main_guard():
    # Only the distribution's default service/config is supported.
    unmanaged_listener = False
    for proc in Path('/proc').glob('[0-9]*/cmdline'):
        try:
            args = proc.read_bytes().split(b'\0')
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
        if args and b'sshd' in Path(os.fsdecode(args[0])).name.encode():
            command = os.fsdecode(b' '.join(args))
            found = re.search(r'(?:^|\s)-f\s*(\S+)', command)
            if found:
                config = found.group(1)
                if config != str(MAIN_CONFIG) and not config.startswith(str(ETC / 'sshd') + '/'):
                    raise Error('发现自定义 SSH 配置 ' + config + '；无法保证账户隔离，请先统一入口。')
            if ('[listener]' in command or ' -D' in command) and not str(ETC / 'sshd') in command:
                unmanaged_listener = True
    managed_main = active('sshd') if OS_ID == 'alpine' else (active('ssh') or active('sshd'))
    if unmanaged_listener and not managed_main:
        raise Error('系统 SSH 监听进程不由标准 ssh/sshd 服务管理，无法确认隔离规则会被加载。')
    if not MAIN_CONFIG.exists():
        raise Error('缺少系统默认 sshd_config，无法配置账户隔离。')
    run(['/usr/sbin/sshd', '-t', '-f', MAIN_CONFIG], capture=True)
    original = MAIN_CONFIG.read_bytes()
    updated = deny_group_config(original.decode())
    if updated.encode() == original:
        return
    backup = ETC / ('system-sshd.before-' + time.strftime('%Y%m%d-%H%M%S') + '.conf')
    atomic(backup, original)
    try:
        atomic(MAIN_CONFIG, updated, stat.S_IMODE(MAIN_CONFIG.stat().st_mode))
        run(['/usr/sbin/sshd', '-t', '-f', MAIN_CONFIG], capture=True)
        reload_main()
    except BaseException:
        atomic(MAIN_CONFIG, original)
        reload_main()
        raise
    print('已添加代理组隔离规则；原 SSH 配置备份：' + str(backup))


def core_ready():
    commands = ('sshd', 'ssh-keygen', 'useradd', 'userdel', 'groupadd', 'chpasswd', 'usermod', 'nologin', 'awk', 'mkfifo', 'wc', 'date')
    if OS_ID == 'alpine':
        commands += ('rc-service', 'rc-update', 'supervise-daemon', 'checkpath')
    search = os.environ['PATH'] + ':/lib/rc/bin:/usr/libexec/rc/bin'
    return all(shutil.which(cmd, path=search) for cmd in commands)


def prepare_sshd_runtime():
    safe_dir('/run/sshd', 0o755)
    if OS_ID == 'alpine':
        safe_dir('/var/empty', 0o755)
    run(['ssh-keygen', '-A'], capture=True)


def prerequisites():
    for cmd in ('sshd', 'ssh-keygen', 'useradd', 'userdel', 'groupadd', 'chpasswd', 'usermod', 'nologin', 'awk', 'mkfifo', 'wc', 'date'):
        if not shutil.which(cmd):
            raise Error('缺少 ' + cmd + '，请从菜单更新/安装依赖。')
    prepare_sshd_runtime()
    # Running the binaries detects missing/broken shared libraries before accounts change.
    run(['ssh-keygen', '-l', '-f', '/etc/ssh/ssh_host_ed25519_key.pub'], capture=True)
    if OS_ID == 'alpine' and not core_ready():
        raise Error('OpenRC 运行组件不完整，请从菜单安装依赖。')
    settings = load_json(GLOBAL)
    try:
        grp.getgrnam(GROUP)
        if not settings.get('owns_group'):
            raise Error('系统已有同名组 ' + GROUP + '，拒绝接管。')
    except KeyError:
        run(['groupadd', '--system', GROUP], capture=True)
        settings['owns_group'] = True
        save_json(GLOBAL, settings)
    ensure_main_guard()
    hostkey = ETC / 'ssh_host_ed25519_key'
    if not hostkey.exists():
        run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', hostkey], capture=True)
    for p, mode in ((ETC / 'sshd', 0o700), (DATA, 0o755),
                    (DATA / 'authorized_keys', 0o755), (DATA / 'homes', 0o755), (LOG, 0o700)):
        safe_dir(p, mode)


def endpoints(value):
    if value in ('any', 'none'):
        return value
    parts = value.split()
    if not parts:
        raise Error('请输入 any、none 或空格分隔的 host:port。')
    for token in parts:
        m = re.fullmatch(r'(\[[0-9a-fA-F:]+\]|[A-Za-z0-9.*_-]+):(\*|[0-9]{1,5})', token)
        if not m or (m.group(2) != '*' and not 1 <= int(m.group(2)) <= 65535):
            raise Error('非法目标：' + token)
        if m.group(1).startswith('['):
            ipaddress.IPv6Address(m.group(1)[1:-1])
        elif '*' in m.group(1) and m.group(1) != '*':
            raise Error('主机通配符仅支持单独的 *。')
    return ' '.join(parts)


def ask_endpoints(label, default, required=False):
    while True:
        try:
            value = endpoints(ask(label, default))
            if required and value == 'none':
                raise Error('此转发方向为当前唯一可用方向，至少需要一个允许范围。')
            return value
        except (Error, ValueError) as e:
            print(e)


def listen_addresses(address):
    if address != 'dual':
        return [str(ipaddress.ip_address(address))]
    if ipv6_disabled():
        return ['0.0.0.0']
    try:
        with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as sock:
            sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            sock.bind(('::', 0))
    except OSError:
        return ['0.0.0.0']
    return ['0.0.0.0', '::']


def available_port(port, address, ignore=None):
    for p in profiles():
        if p['name'] != ignore and p['port'] == port:
            raise Error('端口已被本脚本账户占用：' + p['name'])
    for addr in listen_addresses(address):
        family = socket.AF_INET6 if ':' in addr else socket.AF_INET
        with socket.socket(family, socket.SOCK_STREAM) as sock:
            try:
                if family == socket.AF_INET6:
                    sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                sock.bind((addr, port))
            except OSError as e:
                raise Error('端口不可监听：' + str(e)) from e


def connection_wizard(p, old=None):
    print('\n这里设置服务器的 SSH 连接端口。SOCKS5 是可选的客户端示例，不会让服务器多开一个端口。')
    while True:
        p['port'] = number('服务器 SSH 接入端口', p.get('port', 2222), 1024)
        try:
            addr = ask('服务器监听地址（双栈：同时接收 IPv4/IPv6；也可填写单个 IP）',
                       '双栈' if p.get('listen', 'dual') == 'dual' else p['listen'])
            addr = 'dual' if addr == '双栈' else addr
            p['listen'] = 'dual' if addr == 'dual' else str(ipaddress.ip_address(addr))
            if addr == 'dual' and len(listen_addresses(addr)) == 1:
                print('本机 IPv6 不可用，本次只监听全部 IPv4；启用 IPv6 后请重新应用连接配置。')
            if not old or (p['port'], p['listen']) != (old['port'], old['listen']):
                available_port(p['port'], p['listen'], p['name'])
            break
        except (ValueError, Error) as e:
            print(e)
    if p.get('forward') == 'remote':
        print('当前仅允许远程转发；如需启用 SOCKS5 示例，请先在权限菜单开放本地/动态转发。')
        p['socks_port'] = None
    elif yes('启用可选的客户端 SOCKS5 连接示例', bool(p.get('socks_port'))):
        p['socks_port'] = number('客户端本地 SOCKS5 示例端口', p.get('socks_port') or 1080, 1024)
    else:
        p['socks_port'] = None
    while True:
        host = ask('连接说明使用的服务器 IP/域名（全部：任一可达地址都能连接）',
                   '全部' if p.get('host', 'any') == 'any' else p['host'])
        host = 'any' if host == '全部' else host
        if re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.:-]{0,252}', host):
            p['host'] = host
            break
        print('请输入域名或未带方括号的 IP。')


def permissions_wizard(p):
    print('\n这个账户只能建立隧道，不能登录服务器执行命令或传文件。')
    options = {'1': '通过服务器访问网站或其他服务（常用，支持 SOCKS5）'}
    if sshd_supports('permitlisten'):
        options.update({'2': '让服务器转发到客户端的服务（远程转发）', '3': '两种用途都允许'})
    else:
        print('当前 OpenSSH 不支持 PermitListen，仅开放本地/动态转发。远程转发需要 OpenSSH 7.8 或更高版本。')
    default = {'local': '1', 'remote': '2', 'yes': '3'}.get(p.get('forward'), '1')
    mode = choose('这个账户用来做什么？', options, default if default in options else '1')
    p['forward'] = {'1': 'local', '2': 'remote', '3': 'yes'}[mode]
    if mode == '2' and p.get('socks_port'):
        print('仅远程转发不支持本地 SOCKS5 示例，已关闭该可选项。')
        p['socks_port'] = None
    p['block_private'] = not yes('允许访问服务器内网和本机服务（不清楚请直接回车）',
                                 not p.get('block_private', True))
    print('访问范围：' + ('仅公网，阻止内网、本机及保留地址。' if p['block_private'] else '允许内网；不要把这个账户交给不信任的人。'))
    open_default = p.get('permit_open', 'any')
    if mode == '1' and open_default == 'none':
        open_default = 'any'
    p['permit_open'] = open_default if mode != '2' else 'none'
    if mode != '2' and yes('另外指定能访问的网站或服务（高级设置）', False):
        print('填主机:端口，例如 example.com:443，多项用空格隔开。any 不额外限制；上面的内网隔离仍然生效。')
        print('域名按客户端填写的文字匹配，域名和对应 IP 不会自动视为同一个目标。')
        p['permit_open'] = ask_endpoints('允许目标', open_default, mode == '1')
    if mode != '1':
        print('远程转发要在服务器上监听一个端口，例如 localhost:8080（只有服务器本机能连接）。')
        listen_default = p.get('permit_listen', 'localhost:8080')
        listen_required = p['permit_open'] == 'none'
        if listen_required and listen_default == 'none':
            listen_default = 'localhost:8080'
        p['permit_listen'] = ask_endpoints('允许远程监听', listen_default, listen_required)
        p['gateway'] = yes('允许 -R 绑定非回环 IP、供外部主机访问', p.get('gateway', False))
    else:
        p['permit_listen'], p['gateway'] = 'none', False
    for key, value in (('alive_interval', 60), ('alive_count', 3), ('max_auth', 3)):
        p.setdefault(key, value)
    if yes('调整断线检测和登录尝试次数（高级设置）', False):
        print('定时检查连接，连续收不到回应就断开；不限制流量或正常在线时长。')
        p['alive_interval'] = number('检查间隔/秒，0 关闭', p['alive_interval'], 0, 3600)
        p['alive_count'] = number('连续无应答次数', p['alive_count'], 1, 100)
        p['max_auth'] = number('单连接最多认证尝试次数', p['max_auth'], 1, 20)


def auth_wizard(p, work, old=None):
    default = {'key': '1', 'password': '2', 'both': '3'}.get(p.get('auth'), '1')
    mode = choose('认证方式', {'1': '公钥（推荐，可导入硬件安全密钥公钥）',
                             '2': '密码', '3': '公钥 + 密码，两项必须都通过'}, default)
    p['auth'] = {'1': 'key', '2': 'password', '3': 'both'}[mode]
    credentials = {'private': None, 'public': None, 'password': None}
    if mode in ('1', '3'):
        options = {'1': '我已有密钥：导入客户端公钥（私钥留在客户端，推荐）',
                   '2': '我还没有密钥：在服务器生成 Ed25519 密钥'}
        existing = DATA / 'authorized_keys' / p['name']
        if old and existing.exists() and existing.read_text().strip():
            options['3'] = '保留当前公钥'
        keymode = choose('设置公钥（替换会撤销所有旧公钥）', options, '3' if '3' in options else '2')
        if keymode == '3':
            credentials['public'] = existing.read_text()
            credentials['keep_private'] = True
        elif keymode == '1':
            print('可以粘贴一行标准公钥，也可以填写公钥文件的绝对路径，文件中允许有多把公钥。公钥前面不能带 authorized_keys 选项。')
            text = ask('公钥或公钥文件路径')
            text = Path(text).read_text() if text.startswith('/') else text
            lines = []
            for line in text.splitlines():
                if not line.strip() or line.lstrip().startswith('#'):
                    continue
                fields = line.split()
                if len(fields) < 2 or fields[0] not in ('ssh-ed25519', 'ssh-rsa',
                        'ecdsa-sha2-nistp256', 'ecdsa-sha2-nistp384', 'ecdsa-sha2-nistp521',
                        'sk-ssh-ed25519@openssh.com', 'sk-ecdsa-sha2-nistp256@openssh.com'):
                    raise Error('只接受标准公钥，不能含命令/转发选项。')
                try:
                    base64.b64decode(fields[1], validate=True)
                except ValueError as e:
                    raise Error('公钥编码无效') from e
                candidate = work / 'check.pub'
                atomic(candidate, ' '.join(fields[:2]) + '\n')
                run(['ssh-keygen', '-l', '-f', candidate], capture=True)
                lines.append(' '.join(fields[:2]))
            if not lines:
                raise Error('没有有效公钥')
            credentials['public'] = '\n'.join(lines) + '\n'
        else:
            ui_text('私钥口令：输入不回显；直接回车表示不加密。生成的私钥和口令会保存在 root 专用凭证库，供菜单查看。', 'warning')
            while True:
                phrase = getpass.getpass(paint('  设置私钥口令（可留空）：', 'title'))
                again = getpass.getpass(paint('  再次输入私钥口令：', 'title'))
                if phrase == again and len(phrase.encode('utf-8')) <= 1000 and not any(c in phrase for c in '\x00\r\n'):
                    break
                print('两次口令须相同，不能含换行或 NUL，UTF-8 编码不得超过 1000 字节。')
            key = work / 'id_ed25519'
            generate_key(key, p['name'], phrase)
            credentials['private'] = key.read_bytes()
            credentials['public'] = key.with_suffix('.pub').read_text()
            credentials['passphrase'] = phrase
    if mode in ('2', '3'):
        if old and old['auth'] in ('password', 'both') and yes('保留当前密码', True):
            pass
        else:
            while True:
                a = getpass.getpass('设置密码（至少 12 字符，不回显）：')
                b = getpass.getpass('再次输入密码：')
                if a == b and len(a) >= 12 and not any(c in a for c in '\x00\r\n'):
                    credentials['password'] = a
                    break
                print('两次密码必须相同，至少 12 个字符，不能含换行或 NUL 字符。')
    return credentials


def generate_key(key, name, phrase):
    # A detached child reads the two prompts from stdin. Never pass secrets via
    # argv/environment; remove askpass settings so a desktop helper cannot intercept.
    env = os.environ.copy()
    for k in ('DISPLAY', 'SSH_ASKPASS', 'SSH_ASKPASS_REQUIRE'):
        env.pop(k, None)
    result = subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-a', '64',
                             '-f', str(key), '-C', 'ssht-' + name],
                            input=(phrase + '\n' + phrase + '\n').encode('utf-8'),
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            env=env, start_new_session=True)
    if result.returncode:
        raise Error('密钥生成失败；未应用账户设置。')


def f2b_wizard(p):
    print('\nfail2ban 按来源 IP 统计登录失败次数，达到阈值后封禁。它不会限制带宽，也不会给成功建立的连接限速。')
    print('如果已经安装 fail2ban，会为这个账户添加独立 jail，保留其他 jail，并沿用已有的全局默认设置。')
    p['f2b'] = yes('安装/启用本账户 fail2ban 防爆破（需要 0.11+）', p.get('f2b', False))
    if p['f2b']:
        p['maxretry'] = number('统计窗口内失败多少次封禁', p.get('maxretry', 5), 1, 1000)
        p['findtime'] = number('失败统计窗口/秒', p.get('findtime', 600), 1, 604800)
        p['bantime'] = number('封禁时间/秒', p.get('bantime', 3600), 1, 31536000)
        print('白名单不封禁；默认仅回环。若添加管理员公网 IP，请确认它不会与代理用户共享。')
        while True:
            value = ask('额外白名单 IP/CIDR，空格分隔，无则填 none', p.get('ignoreip', 'none'))
            try:
                if value != 'none':
                    value = ' '.join(str(ipaddress.ip_network(x, strict=False)) for x in value.split())
                p['ignoreip'] = value
                break
            except ValueError:
                print('请输入合法 IP/CIDR。')


def render_sshd(p):
    permit_listen = sshd_supports('permitlisten')
    if not permit_listen and p['forward'] != 'local':
        raise Error('当前 OpenSSH 不支持 PermitListen，无法安全应用远程转发限制。请改用本地/动态转发，或升级 OpenSSH 至 7.8+。')
    light = p.get('light', LIGHT)
    password = p['auth'] in ('password', 'both')
    public = p['auth'] in ('key', 'both')
    auth = {'key': 'publickey', 'password': 'password', 'both': 'publickey,password'}[p['auth']]
    return '\n'.join([
        '# Generated by SSHT; edit via menu', 'Port ' + str(p['port']),
        'AddressFamily any', *['ListenAddress ' + a for a in listen_addresses(p['listen'])],
        'HostKey ' + str(ETC / 'ssh_host_ed25519_key'),
        'PidFile /run/ssht-' + p['name'] + '.pid', 'AllowUsers ' + p['name'],
        'PermitRootLogin no', 'StrictModes yes', 'PermitEmptyPasswords no',
        'PubkeyAuthentication ' + ('yes' if public else 'no'),
        'PasswordAuthentication ' + ('yes' if password else 'no'),
        'ChallengeResponseAuthentication no', 'AuthenticationMethods ' + auth,
        'AuthorizedKeysFile ' + str(DATA / 'authorized_keys' / p['name']),
        *(['UsePAM no'] if OS_ID != 'alpine' else []),
        'HostbasedAuthentication no', 'IgnoreRhosts yes',
        'MaxSessions 0', 'PermitTTY no', 'ForceCommand /bin/false',
        'PermitUserRC no', 'AllowAgentForwarding no', 'X11Forwarding no',
        'AllowStreamLocalForwarding no', 'PermitTunnel no',
        'AllowTcpForwarding ' + p['forward'],
        'PermitOpen ' + p['permit_open'],
        *(['PermitListen ' + p['permit_listen']] if permit_listen else []),
        'GatewayPorts ' + ('clientspecified' if p['gateway'] else 'no'),
        'ClientAliveInterval ' + str(p['alive_interval']),
        'ClientAliveCountMax ' + str(p['alive_count']),
        'MaxAuthTries ' + str(p['max_auth']), 'LoginGraceTime ' + ('20' if light else '30'),
        'MaxStartups ' + ('2:30:4' if light else '10:30:60'),
        'LogLevel ' + ('QUIET' if light and not p.get('f2b') else 'INFO'),
        'UseDNS no', 'Compression no', ''])


def service_file(name):
    unit = 'ssht-' + name
    return Path('/etc/init.d') / unit if OS_ID == 'alpine' else Path('/etc/systemd/system') / (unit + '.service')


def logger_script(name):
    return SCRIPT.parent / ('serve-' + name + '.sh')


def firewall_script(name):
    return SCRIPT.parent / ('egress-' + name + '.sh')


def secret_path(name):
    return ETC / 'secrets' / (name + '.json')


def firewall_ready():
    if not all(shutil.which(n) for n in ('iptables', 'ip6tables', 'iptables-restore', 'ip6tables-restore')):
        update_packages()
    # IPv6 may be administratively disabled. The generated guard repeats this
    # check at every start, so enabling it later cannot start an unfiltered daemon.
    for cmd in ('iptables', 'ip6tables'):
        if cmd == 'ip6tables' and ipv6_disabled():
            continue
        if not shutil.which(cmd) or run([cmd, '-w', '5', '-S', 'OUTPUT'], check=False, capture=True).returncode:
            raise Error('默认内网隔离需要 iptables/ip6tables 和容器 NET_ADMIN 权限。当前环境无法管理规则，账户未应用；请让容器提供方开放权限，或在权限菜单明确允许内网访问。')


def ipv6_disabled():
    root = Path('/proc/sys/net/ipv6/conf')
    if not root.exists():
        return True
    flags = list(root.glob('*/disable_ipv6'))
    return bool(flags) and all(flag.read_text().strip() == '1' for flag in flags)


def firewall_rules(p, ipv6=False):
    chain = 'sshto-' + p['name']
    tag = 'ssht:{}:{}'.format(p['name'], p['uid'])
    lines = ['*filter', ':' + chain + ' - [0:0]', '-F ' + chain,
             '-A ' + chain + ' -m comment --comment ' + tag,
             # Inbound SSH replies must work even when the client is on a LAN.
             '-A ' + chain + ' -m conntrack --ctdir REPLY -j RETURN',
             '-A ' + chain + ' -p tcp -m addrtype --dst-type LOCAL -j REJECT --reject-with tcp-reset']
    blocked = (['2001::/23', '2001:db8::/32', '2002::/16', '3fff::/20'] if ipv6 else
               ['0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8',
                '169.254.0.0/16', '172.16.0.0/12', '192.0.0.0/24', '192.0.2.0/24',
                '192.88.99.0/24', '192.168.0.0/16', '198.18.0.0/15',
                '198.51.100.0/24', '203.0.113.0/24', '224.0.0.0/3'])
    if ipv6:
        # Public unicast only: this also excludes ULA, link-local, loopback,
        # IPv4 translation prefixes and multicast. IPv4-mapped sockets use IPv4 rules.
        lines.append('-A ' + chain + ' -p tcp ! -d 2000::/3 -j REJECT --reject-with tcp-reset')
    lines += ['-A ' + chain + ' -p tcp -d ' + net + ' -j REJECT --reject-with tcp-reset' for net in blocked]
    lines += ['-A ' + chain + ' -j RETURN', 'COMMIT', '']
    return '\n'.join(lines)


def render_firewall(p):
    if not p.get('block_private', False):
        return '#!/bin/sh\n# SSHT: this account explicitly permits private destinations.\nexit 0\n'
    return '''#!/bin/sh
# SSHT managed egress policy. Called before sshd, never a resident process.
set -eu
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
chain={chain}
tag={tag}
uid={uid}
action=${{1:-apply}}
case "$action" in apply|remove) ;; *) exit 2 ;; esac
policy() {{
    tool=$1
    "$tool" -w 5 -S OUTPUT >/dev/null
    if "$tool" -w 5 -S "$chain" >/dev/null 2>&1; then
        "$tool" -w 5 -C "$chain" -m comment --comment "$tag" || {{
            echo 'SSHT: refusing a firewall chain owned by another configuration' >&2
            exit 1
        }}
    elif [ "$action" = remove ]; then
        return
    else
        "$tool" -w 5 -N "$chain"
        "$tool" -w 5 -A "$chain" -m comment --comment "$tag"
    fi
    if [ "$action" = remove ]; then
        for mark in "$tag" "$tag:guard"; do
            while "$tool" -w 5 -C OUTPUT -p tcp -m owner --uid-owner "$uid" -m comment --comment "$mark" -j "$chain" 2>/dev/null; do
                "$tool" -w 5 -D OUTPUT -p tcp -m owner --uid-owner "$uid" -m comment --comment "$mark" -j "$chain"
            done
        done
        "$tool" -w 5 -F "$chain"
        "$tool" -w 5 -X "$chain"
        return
    fi
    # --noflush preserves every other chain. The replacement is one filter-table commit.
    if [ "$tool" = iptables ]; then
        iptables-restore --noflush <<'SSHT_IPV4'
{v4}SSHT_IPV4
    else
        ip6tables-restore --noflush <<'SSHT_IPV6'
{v6}SSHT_IPV6
    fi
    # Always place our check ahead of broad OUTPUT ACCEPT rules.
    # A temporary identical jump prevents an unfiltered gap while moving it.
    "$tool" -w 5 -I OUTPUT 1 -p tcp -m owner --uid-owner "$uid" -m comment --comment "$tag:guard" -j "$chain"
    while "$tool" -w 5 -C OUTPUT -p tcp -m owner --uid-owner "$uid" -m comment --comment "$tag" -j "$chain" 2>/dev/null; do
        "$tool" -w 5 -D OUTPUT -p tcp -m owner --uid-owner "$uid" -m comment --comment "$tag" -j "$chain"
    done
    "$tool" -w 5 -I OUTPUT 1 -p tcp -m owner --uid-owner "$uid" -m comment --comment "$tag" -j "$chain"
    while "$tool" -w 5 -C OUTPUT -p tcp -m owner --uid-owner "$uid" -m comment --comment "$tag:guard" -j "$chain" 2>/dev/null; do
        "$tool" -w 5 -D OUTPUT -p tcp -m owner --uid-owner "$uid" -m comment --comment "$tag:guard" -j "$chain"
    done
}}
policy iptables
ipv6_off=yes
if [ -d /proc/sys/net/ipv6/conf ]; then
    for flag in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
        if [ ! -f "$flag" ] || [ "$(cat "$flag")" != 1 ]; then ipv6_off=no; fi
    done
fi
if [ "$ipv6_off" = no ]; then
    policy ip6tables
elif [ "$action" = remove ] && ip6tables -w 5 -S "$chain" >/dev/null 2>&1; then
    policy ip6tables
fi
'''.format(chain='sshto-' + p['name'], tag='ssht:{}:{}'.format(p['name'], p['uid']),
           uid=int(p['uid']), v4=firewall_rules(p), v6=firewall_rules(p, True))


def remove_firewall(p):
    path = firewall_script(p['name'])
    if p.get('block_private'):
        if not path.exists():
            raise Error('账户防火墙脚本缺失，无法确认规则已清理；请恢复 ' + str(path) + ' 后重试。')
        run(['/bin/sh', path, 'remove'], capture=True)


def store_credentials(p, credentials):
    path = secret_path(p['name'])
    if p['auth'] == 'password' or (credentials.get('public') is not None and
                                 not credentials.get('keep_private') and not credentials.get('private')):
        unlink_if_exists(path)
    elif credentials.get('private'):
        save_json(path, {'private': credentials['private'].decode('utf-8'),
                         'public': credentials['public'], 'passphrase': credentials.get('passphrase'),
                         'uid': p['uid']})


def log_budget():
    disk = os.statvfs(str(LOG))
    total = disk.f_blocks * disk.f_frsize
    settings = load_json(GLOBAL)
    return min(total, int(settings.get('log_budget_mib', 0)) * 1024 ** 2 or total // 10)


def configure_log_limits(extra=None):
    safe_dir(LOG)
    safe_dir(ETC / 'log-limits')
    names = set(p['name'] for p in profiles())
    if extra:
        names.add(extra)
    cap = max(1, log_budget() // max(1, len(names)))
    # Publish smaller limits first. Writers re-read the cap before every record.
    for name in sorted(names):
        atomic(ETC / 'log-limits' / name, str(cap) + '\n')
    for name in sorted(names):
        for path in LOG.glob(name + '.log*'):
            if path.is_symlink() or not path.is_file():
                raise Error('日志路径不安全：' + str(path))
            if path.name != name + '.log':
                # Old versions used logrotate archives; remove only its known names.
                if re.fullmatch(re.escape(name) + r'\.log\.\d+(?:\.gz)?', path.name):
                    path.unlink()
            elif path.stat().st_size > cap:
                with path.open('r+b') as output:
                    output.truncate(0)


def log_settings():
    for p in profiles():
        unit = service_file(p['name'])
        if unit.exists() and str(logger_script(p['name'])) not in unit.read_text():
            raise Error('账户 ' + p['name'] + ' 仍使用旧服务。请先在修改菜单重新应用配置，再设置日志额度。')
    print('当前隧道日志总额度：{:.2f} MiB；所有账户均分，写满后清空该账户旧日志。'.format(log_budget() / 1024 ** 2))
    mode = choose('日志总额度', {'1': '自动：日志文件系统总容量的 10%', '2': '自定义 MiB'}, '1')
    settings = load_json(GLOBAL)
    if mode == '1':
        settings.pop('log_budget_mib', None)
    else:
        disk = os.statvfs(str(LOG))
        maximum = max(1, disk.f_blocks * disk.f_frsize // 1024 ** 2)
        settings['log_budget_mib'] = number('日志总额度/MiB', max(1, int(log_budget() / 1024 ** 2)), 1, maximum)
    save_json(GLOBAL, settings)
    configure_log_limits()
    print('日志额度已更新。超额的旧日志已清空，连接不受影响。')


def render_logger(name, quiet=False, guard=False):
    preflight = '/bin/sh {} apply || exit $?\n'.format(shlex.quote(str(firewall_script(name)))) if guard else ''
    if quiet:
        # exec replaces the shell: no awk/FIFO/log writer in the smallest mode.
        return '#!/bin/sh\n' + preflight + 'exec /usr/sbin/sshd -D -f {} -E /dev/null\n'.format(
            shlex.quote(str(ETC / 'sshd' / (name + '.conf'))))
    clock = run(['awk', 'BEGIN { print strftime("%s") }'], capture=True, check=False)
    timestamp = '    stamp = strftime("%b %d %H:%M:%S")'
    if clock.returncode:
        # Debian 9's mawk lacks strftime. Only that fallback forks date per record.
        timestamp = '    stamp_cmd = "date +\\"%b %d %H:%M:%S\\""\n    if ((stamp_cmd | getline stamp) <= 0) exit 1\n    close(stamp_cmd)'
    # A small POSIX shell + awk writer, no resident Python and no polling timer.
    # One bounded file per account. LC_ALL=C makes length() count bytes.
    return '''#!/bin/sh
set -eu
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LC_ALL=C
export PATH LC_ALL
umask 077
{preflight}
pipe_dir=$(mktemp -d /run/ssht-{name}.XXXXXX)
pipe=$pipe_dir/logpipe
child=
writer=
cleanup() {{
    trap - EXIT HUP INT TERM
    [ -z "$child" ] || kill "$child" 2>/dev/null || :
    [ -z "$writer" ] || kill "$writer" 2>/dev/null || :
    wait 2>/dev/null || :
    rm -f "$pipe"
    rmdir "$pipe_dir" 2>/dev/null || :
}}
trap cleanup EXIT
trap 'exit 0' HUP INT TERM
mkfifo -m 600 "$pipe"
/usr/sbin/sshd -D -e -f {config} >"$pipe" 2>&1 &
child=$!
awk -v file={log} -v limit={limit} -v used="$(wc -c <{log})" '
{{
    if ((getline cap < limit) <= 0 || cap !~ /^[0-9]+$/ || cap < 1) exit 1
    close(limit)
{timestamp}
    line = stamp " ssht sshd: " $0 "\\n"
    if (length(line) > cap) line = substr(line, 1, cap)
    if (used + length(line) > cap) {{
        printf "%s", "" > file
        close(file)
        used = 0
    }}
    printf "%s", line >> file
    close(file)
    used += length(line)
}}' <"$pipe" &
writer=$!
# If the writer fails, stop sshd instead of allowing unbounded or blocked output.
wait "$writer"
exit 1
'''.format(name=name, config=shlex.quote(str(ETC / 'sshd' / (name + '.conf'))),
           log=shlex.quote(str(LOG / (name + '.log'))),
           limit=shlex.quote(str(ETC / 'log-limits' / name)), timestamp=timestamp, preflight=preflight)


def render_service(name):
    config = ETC / 'sshd' / (name + '.conf')
    log = LOG / (name + '.log')
    if OS_ID == 'alpine':
        return '''#!/sbin/openrc-run
# Generated by SSHT
description="SSHT tunnel for {name}"
supervisor="supervise-daemon"
command="{launcher}"
respawn_delay=3
respawn_max=5
depend() {{
    need net
    after firewall
}}
start_pre() {{
    checkpath --directory --mode 0755 /run/sshd
    /usr/sbin/sshd -t -f {config}
}}
'''.format(name=name, config=config, launcher=logger_script(name))
    return '''# Generated by SSHT
[Unit]
Description=SSHT tunnel for {name}
After=network.target
[Service]
Type=simple
ExecStartPre=/usr/bin/mkdir -p /run/sshd
ExecStartPre=/usr/sbin/sshd -t -f {config}
ExecStart={launcher}
Restart=on-failure
RestartSec=3
KillMode=control-group
[Install]
WantedBy=multi-user.target
'''.format(name=name, config=config, launcher=logger_script(name))


def jail_path(name):
    return Path('/etc/fail2ban/jail.d') / ('ssht-' + name + '.local')


def render_jail(p):
    # Explicit port-scoped action supports both IPv4/IPv6 through fail2ban's iptables action.
    extra = '' if p.get('ignoreip', 'none') == 'none' else ' ' + p['ignoreip']
    return '''# Generated by SSHT; existing jails are preserved
[ssht-{name}]
enabled = true
filter = sshd
backend = polling
logpath = {log}
port = {port}
protocol = tcp
maxretry = {maxretry}
findtime = {findtime}
bantime = {bantime}
ignoreip = 127.0.0.1/8 ::1{extra}
action = iptables-multiport[name=ssht-{name}, port="{port}", protocol=tcp]
'''.format(log=LOG / (p['name'] + '.log'), extra=extra, **p)


def reload_f2b(name):
    require_f2b_version()
    run(['fail2ban-client', '-t'], capture=True)
    service('fail2ban', 'enable')
    if active('fail2ban'):
        jail = 'ssht-' + name
        if jail_path(name).exists():
            run(['fail2ban-client', 'reload', '--restart', '--if-exists', jail], capture=True)
        elif run(['fail2ban-client', 'status', jail], check=False, capture=True).returncode == 0:
            run(['fail2ban-client', 'stop', jail], capture=True)
    else:
        service('fail2ban', 'start')


def require_f2b_version():
    version = run(['fail2ban-client', '-V'], capture=True).stdout
    match = re.search(r'(\d+)\.(\d+)', version)
    if not match or tuple(int(n) for n in match.groups()) < (0, 11):
        raise Error('独立 jail 管理需要 fail2ban 0.11+。旧系统可以关闭此项，继续使用 SSH 隧道；脚本不会升级系统或接管其他 jail。')


def validate_f2b(p):
    if p.get('f2b'):
        # Read-only capability check; never add synthetic bans to the user's firewall.
        tool = 'ip6tables' if ':' in p['listen'] else 'iptables'
        run([tool, '-w', '5', '-n', '-L', 'INPUT'], capture=True)
    reload_f2b(p['name'])
    if p.get('f2b'):
        run(['fail2ban-client', 'status', 'ssht-' + p['name']], capture=True)


def password_set(name, password):
    run(['chpasswd'], input=name + ':' + password + '\n', capture=True)


def verify_owned(p):
    try:
        user = pwd.getpwnam(p['name'])
        group = grp.getgrnam(GROUP)
    except KeyError as e:
        raise Error('系统账户/组缺失，请人工检查后再操作。') from e
    if user.pw_uid != p['uid'] or user.pw_gid != group.gr_gid or user.pw_dir != str(DATA / 'homes' / p['name']):
        raise Error('账户 UID/组/home 与记录不一致，拒绝接管或删除。')
    return user


def stop_user(p):
    # Stop supervisor first, then reap remaining forwarding children on both init systems.
    result = service('ssht-' + p['name'], 'stop', False)
    if result.returncode and active('ssht-' + p['name']):
        raise Error('无法停止隧道服务：' + (result.stdout or ''))
    uid = verify_owned(p).pw_uid
    for proc in Path('/proc').glob('[0-9]*/status'):
        try:
            m = re.search(r'^Uid:\s+(\d+)', proc.read_text(), re.M)
            if m and int(m.group(1)) == uid:
                os.kill(int(proc.parent.name), signal.SIGKILL)
        except (FileNotFoundError, ProcessLookupError):
            pass


def wait_service(p):
    for _ in range(30):
        if active('ssht-' + p['name']):
            try:
                for address in listen_addresses(p['listen']):
                    host = {'0.0.0.0': '127.0.0.1', '::': '::1'}.get(address, address)
                    if address == '::':
                        # Some containers enable IPv6 only on their network interface.
                        hosts = []
                        for line in Path('/proc/net/if_inet6').read_text().splitlines():
                            fields = line.split()
                            ip = ipaddress.IPv6Address(int(fields[0], 16))
                            hosts.append(str(ip) + ('%' + fields[-1] if ip.is_link_local else ''))
                        if hosts and '::1' not in hosts:
                            host = hosts[0]
                    with socket.create_connection((host, p['port']), timeout=0.5) as conn:
                        if not conn.recv(255).startswith(b'SSH-'):
                            raise OSError('未收到 SSH 握手')
                return
            except OSError:
                pass
        time.sleep(0.2)
    raise Error('未能确认隧道服务正在运行并返回 SSH 握手信息，请查看日志：' + str(LOG / (p['name'] + '.log')))


class Transaction:
    """Persist rollback material before each mutation; also survives an interrupted UI."""
    def __init__(self, name):
        self.dir = Path(tempfile.mkdtemp(prefix='txn-' + name + '-', dir=str(ETC)))
        self.files = OrderedDict()

    def watch(self, path):
        path = Path(path)
        if path in self.files:
            return
        if path.is_symlink():
            raise Error('拒绝接管符号链接：' + str(path))
        old = (path.read_bytes(), stat.S_IMODE(path.stat().st_mode)) if path.exists() else None
        self.files[path] = old
        if old:
            atomic(self.dir / str(len(self.files)), old[0], 0o600)
        save_json(self.dir / 'manifest.json', [
            {'path': str(k), 'backup': str(i) if v else None, 'mode': v[1] if v else None}
            for i, (k, v) in enumerate(self.files.items(), 1)])

    def restore(self):
        for path, old in self.files.items():
            if old is None:
                unlink_if_exists(path)
            else:
                atomic(path, old[0], old[1])

    def finish(self):
        shutil.rmtree(str(self.dir))


def apply_profile(p, credentials, old=None):
    name = p['name']
    prerequisites()
    p['light'] = p.get('light', False) or LIGHT
    # Reject unsupported permissions before making an account or changing a jail.
    render_sshd(p)
    if p.get('block_private'):
        firewall_ready()
    safe_dir(ETC / 'secrets')
    if p.get('f2b'):
        if not all(pkg_installed(n) for n in (['fail2ban', 'iptables', 'ip6tables']
                                             if OS_ID == 'alpine' else ['fail2ban', 'iptables'])):
            update_packages(True)
        require_f2b_version()
        safe_dir('/etc/fail2ban/jail.d', 0o755)
    config = ETC / 'sshd' / (name + '.conf')
    keys = DATA / 'authorized_keys' / name
    unit = service_file(name)
    jail = jail_path(name)
    logfile = LOG / (name + '.log')
    rotation = Path('/etc/logrotate.d') / ('ssht-' + name)
    if not old:
        for path in (config, keys, unit, jail, logfile, DATA / 'homes' / name, rotation,
                     profile_path(name), secret_path(name), firewall_script(name)):
            if path.exists() or path.is_symlink():
                raise Error('同名资源已存在，拒绝覆盖：' + str(path))
        if OS_ID != 'alpine':
            state = run(['systemctl', 'show', '-p', 'LoadState', '--value', 'ssht-' + name],
                        check=False, capture=True).stdout.strip()
            if state and state != 'not-found':
                raise Error('发现同名 systemd 服务，拒绝覆盖：ssht-' + name)
    txn = Transaction(name)
    for path in (config, keys, unit, rotation, logger_script(name), profile_path(name),
                 secret_path(name), firewall_script(name)):
        txn.watch(path)
    if not old:
        txn.watch(logfile)
    if jail.parent.exists():
        txn.watch(jail)
    made_user = False
    made_home = False
    was_active = active('ssht-' + name) if old else False
    old_shadow = None
    guard_written = False
    try:
        if old:
            verify_owned(old)
            old_shadow = next(line.split(':')[1] for line in Path('/etc/shadow').read_text().splitlines()
                              if line.split(':')[0] == name)
            save_json(txn.dir / 'account.json', {'name': name, 'uid': old['uid'], 'created': False,
                      'old_shadow': old_shadow, 'was_active': was_active, 'enabled': old.get('enabled', True)})
        else:
            try:
                pwd.getpwnam(name)
                raise Error('系统已有同名账户，拒绝接管。')
            except KeyError:
                pass
            home = DATA / 'homes' / name
            safe_dir(home, 0o755)
            made_home = True
            shell = shutil.which('nologin')
            if not shell:
                raise Error('缺少 nologin')
            save_json(txn.dir / 'account.json', {'name': name, 'uid': None, 'created': True})
            run(['useradd', '-l', '-M', '-d', home, '-s', shell, '-g', GROUP, '-c', 'SSHT tunnel', name], capture=True)
            made_user = True
            p['uid'] = pwd.getpwnam(name).pw_uid
            save_json(txn.dir / 'account.json', {'name': name, 'uid': p['uid'], 'created': True})
            # OpenSSH without PAM rejects locked accounts even for keys. An unknown random
            # password unlocks the account; key-only daemon still disables password auth.
            password_set(name, random_password())
        if credentials.get('public') is not None:
            atomic(keys, credentials['public'], 0o644)
        elif p['auth'] == 'password':
            atomic(keys, '', 0o644)
        store_credentials(p, credentials)
        atomic(config, render_sshd(p))
        run(['/usr/sbin/sshd', '-t', '-f', config], capture=True)
        atomic(unit, render_service(name), 0o755 if OS_ID == 'alpine' else 0o644)
        if not logfile.exists():
            atomic(logfile, '')
        unlink_if_exists(rotation)
        configure_log_limits(name)
        atomic(logger_script(name), render_logger(name, p.get('light') and not p.get('f2b'), guard=True), 0o700)
        if p.get('f2b'):
            atomic(jail, render_jail(p), 0o644)
        elif jail.exists():
            jail.unlink()
        if p.get('f2b') or (old and old.get('f2b')):
            validate_f2b(p)
        # Validate all files before interrupting an existing tunnel or changing its password.
        if old:
            stop_user(old)
            if old.get('block_private') and not p.get('block_private'):
                remove_firewall(old)
        atomic(firewall_script(name), render_firewall(p), 0o700)
        guard_written = True
        if p.get('block_private'):
            run(['/bin/sh', firewall_script(name), 'apply'], capture=True)
        if credentials.get('password'):
            password_set(name, credentials['password'])
        elif p['auth'] == 'key' and old and old['auth'] != 'key':
            password_set(name, random_password())
        if OS_ID != 'alpine':
            run(['systemctl', 'daemon-reload'], capture=True)
        service('ssht-' + name, 'enable')
        service('ssht-' + name, 'start')
        wait_service(p)
        p['enabled'] = True
        save_json(profile_path(name), p)
        txn.finish()
        print('账户配置已生效：' + name)
    except BaseException:
        print('操作失败，正在恢复本次修改。')
        try:
            service('ssht-' + name, 'stop', False)
            if guard_written:
                remove_firewall(p)
            if made_user:
                stop_user(p)
                run(['userdel', name], capture=True)
                service('ssht-' + name, 'disable', False)
            if made_home and (DATA / 'homes' / name).exists():
                shutil.rmtree(str(DATA / 'homes' / name))
            txn.restore()
            if old and old.get('block_private'):
                run(['/bin/sh', firewall_script(name), 'apply'], capture=True)
            if old_shadow is not None:
                run(['chpasswd', '-e'], input=name + ':' + old_shadow + '\n', capture=True)
            if OS_ID != 'alpine':
                run(['systemctl', 'daemon-reload'], capture=True)
            if pkg_installed('fail2ban') and (p.get('f2b') or (old and old.get('f2b'))):
                reload_f2b(name)
            if old and was_active:
                service('ssht-' + name, 'start')
                wait_service(old)
            if old and not old.get('enabled', True):
                service('ssht-' + name, 'disable')
            txn.finish()
        except BaseException as recovery:
            print('自动恢复未完成：{}\n备份保留在 {}，请先修复再继续。'.format(recovery, txn.dir))
        raise


def connection_host(p):
    host = p['host']
    if host == 'any':
        # Reuse the address the administrator connected to; no external IP lookup.
        parts = os.environ.get('SSH_CONNECTION', '').split()
        host = parts[2] if len(parts) == 4 else 'SERVER_IP'
        try:
            host = str(ipaddress.ip_address(host))
        except ValueError:
            host = 'SERVER_IP'
    return host


def connection_text(p):
    auth = '-i ./id_ed25519 ' if p['auth'] in ('key', 'both') else ''
    host = connection_host(p)
    base = 'ssh -N -T -o ExitOnForwardFailure=yes -o ServerAliveInterval=60 ' + auth + '-p {} {}@{}'.format(p['port'], p['name'], host)
    lines = ['账户：' + p['name'], '认证方式：' + p['auth'], '服务器主机公钥指纹：']
    lines.append(run(['ssh-keygen', '-lf', ETC / 'ssh_host_ed25519_key.pub'], capture=True).stdout.strip())
    if p['host'] == 'any':
        lines += ['连接地址未限定：可使用服务器任一可达 IP 或域名，脚本不限制客户端来源 IP。',
                  '下面地址仅供示例；若显示 SERVER_IP，请换成服务器控制台提供的 IP 或域名。']
    lines += ['SSH 接入：主机 {}，端口 {}，用户名 {}'.format(host, p['port'], p['name']),
              '客户端请使用纯隧道模式（不请求 Shell/PTY），密钥认证使用对应私钥。']
    if p['forward'] in ('local', 'yes'):
        if p.get('socks_port'):
            lines += ['可选 SOCKS5（客户端执行；将 id_ed25519 换成自己的私钥路径）：',
                      base + ' -D 127.0.0.1:' + str(p['socks_port']),
                      '客户端代理地址 127.0.0.1:' + str(p['socks_port']) + '，可启用代理 DNS。']
        lines += ['本地转发模板：' + base + ' -L 127.0.0.1:15432:TARGET_HOST:5432']
    if p['forward'] in ('remote', 'yes'):
        lines += ['远程转发模板（按 PermitListen 替换监听地址和端口）：',
                  base + ' -R localhost:8080:127.0.0.1:80']
    lines += ['内网访问：' + ('禁止（同时阻止本机及保留地址）' if p.get('block_private') else '允许；仍受目标名单限制'),
              '允许访问的目标：' + p['permit_open'], '远程监听范围：' + p['permit_listen'],
              '请先放行服务器/云安全组 TCP ' + str(p['port']) + '；脚本不自动开放防火墙。',
              'SSH 动态代理承载 TCP，不支持通用 UDP。首次连接请核对以上主机指纹。']
    return '\n'.join(lines) + '\n'


def prepare_export(p, credentials):
    required = credentials.get('private') is not None
    if required:
        print('请先把新生成的私钥保存到安全目录，再应用账户设置。以后登录需要这把私钥。')
    elif not yes('保存公钥/连接说明，或选择保存刚输入的密码', False):
        return None
    while True:
        dest = Path(ask('凭证父目录（绝对路径；须归 root 所有）', '/root/ssht-credentials')).expanduser()
        if not dest.is_absolute():
            print('请使用绝对路径。')
            continue
        try:
            safe_dir(dest)
            dest = Path(tempfile.mkdtemp(prefix=p['name'] + '-', dir=str(dest)))
            break
        except Error as e:
            print(e)
    try:
        if credentials.get('private'):
            atomic(dest / 'id_ed25519', credentials['private'])
        if credentials.get('public'):
            atomic(dest / 'authorized_keys.pub', credentials['public'])
        if credentials.get('password') and yes('额外保存明文密码到 root 专用文件（默认不保存）', False):
            atomic(dest / 'password.txt', credentials['password'] + '\n')
        # Host key/connection instructions are added after prerequisites and deployment.
        atomic(dest / 'STATUS.txt', '尚未完成部署；请以菜单执行结果为准。\n')
        print('凭证已保存（目录 700，文件 600）：' + str(dest))
        return dest
    except BaseException:
        shutil.rmtree(str(dest))
        raise


def complete_export(p, dest):
    text = connection_text(p)
    print('\n' + text)
    if dest:
        atomic(dest / 'connection.txt', text)
        if (dest / 'id_ed25519').exists() and p['auth'] == 'key' and p['forward'] in ('local', 'yes'):
            saved = read_credentials(p)
            if saved and saved.get('passphrase') is not None:
                atomic(dest / 'mihomo.yaml', mihomo_config(p, saved))
                print('已生成 mihomo.yaml：将它安全下载到客户端，再导入使用 Mihomo 内核的 Clash 客户端。文件含私钥，请勿公开。')
                if connection_host(p) == 'SERVER_IP':
                    ui_text('未能识别服务器连接地址，请先把 mihomo.yaml 中的 SERVER_IP 改成服务器 IP 或域名。', 'warning')
        atomic(dest / 'STATUS.txt', '部署成功。\n')
        print('凭证目录：' + str(dest) + '；请安全转移到客户端，按需删除服务器副本。')


def mihomo_config(p, saved):
    # JSON quoted strings are valid YAML scalars, including multiline key material.
    quote = lambda value: json.dumps(value, ensure_ascii=False)
    public = (ETC / 'ssh_host_ed25519_key.pub').read_text().split()
    return '\n'.join([
        '# 含登录私钥，请勿分享。本配置需要支持 SSH 节点的 Mihomo 内核。',
        'mixed-port: 7890', 'allow-lan: false', 'mode: rule', 'log-level: warning',
        'proxies:', '  - name: SSHT', '    type: ssh',
        '    server: ' + quote(connection_host(p)), '    port: ' + str(p['port']),
        '    username: ' + quote(p['name']), '    private-key: ' + quote(saved['private']),
        '    private-key-passphrase: ' + quote(saved['passphrase']),
        '    host-key:', '      - ' + quote(' '.join(public[:2])),
        'proxy-groups:', '  - name: SSH隧道', '    type: select', '    proxies: [SSHT]',
        'rules:', '  - MATCH,SSH隧道', ''])


def create_user():
    if not shutil.which('ssh-keygen'):
        raise Error('缺少 ssh-keygen，请先从菜单安装依赖。')
    prepare_sshd_runtime()
    p = {}
    while True:
        name = ask('新增账户名（小写字母开头，最多 20 字符）', 'ssht')
        if valid_name(name):
            try:
                pwd.getpwnam(name)
            except KeyError:
                if not profile_path(name).exists():
                    p['name'] = name
                    break
        print('账户名无效或已存在；不会接管已有系统账户。')
    with tempfile.TemporaryDirectory(prefix='credentials-', dir=str(ETC)) as td:
        connection_wizard(p)
        permissions_wizard(p)
        if p.get('block_private'):
            firewall_ready()
        credentials = auth_wizard(p, Path(td))
        f2b_wizard(p)
        print('\n请核对创建内容：')
        print(profile_summary(p))
        if not yes('确认创建', True):
            return
        dest = prepare_export(p, credentials)
        apply_profile(p, credentials)
        complete_export(p, dest)


def profile_summary(p):
    return '\n'.join([
        '用户名：' + p['name'], '服务器端口：' + str(p['port']),
        '监听地址：' + ('双栈（IPv6 不可用时仅 IPv4）' if p['listen'] == 'dual' else p['listen']),
        '连接地址：' + ('服务器任一可达 IP/域名' if p.get('host') == 'any' else p.get('host', '')),
        '登录方式：' + {'key': '密钥', 'password': '密码', 'both': '密钥和密码均需验证'}[p['auth']],
        '用途：' + {'local': '通过服务器访问其他服务', 'remote': '转发到客户端服务', 'yes': '双向转发'}[p['forward']],
        '服务器内网访问：' + ('禁止' if p.get('block_private') else '允许（旧账户可能尚未启用隔离）'),
        '额外目标限制：' + {'any': '无', 'none': '禁止本地/动态转发'}.get(p['permit_open'], p['permit_open']),
        '登录防爆破：' + ('已启用' if p.get('f2b') else '未启用')])


def read_credentials(p):
    path = secret_path(p['name'])
    if not path.exists():
        return None
    safe_dir(path.parent)
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o600:
        raise Error('凭证文件须归 root 所有且权限为 600，拒绝读取不安全文件。')
    value = load_json(path)
    public = DATA / 'authorized_keys' / p['name']
    if value.get('uid') != p['uid'] or not public.exists() or value.get('public') != public.read_text():
        raise Error('保存的私钥与当前账户记录不匹配；请重新设置密钥。')
    return value


def view_users():
    p = select_user()
    print(profile_summary(p))
    mode = choose('查看账户资料', {'1': '公钥', '2': '私钥和私钥口令（敏感信息，会显示在屏幕上）',
                                  '3': '连接方法'})
    if mode == '1':
        key = DATA / 'authorized_keys' / p['name']
        print(key.read_text().strip() if key.exists() and key.read_text().strip() else '该账户未设置公钥。')
    elif mode == '2':
        value = read_credentials(p)
        if value is None:
            print('没有保存这位用户的私钥或口令。导入公钥时私钥留在客户端，旧版本未保存的口令也无法找回。')
            print('需要新密钥时，请返回主菜单，选择“修改用户”中的登录方式。')
            return
        ui_text('以下是登录凭证，请勿分享屏幕或把内容发到群聊。', 'warning')
        print(value['private'].rstrip())
        phrase = value.get('passphrase')
        print(paint('私钥口令：', 'title') + ('未保存，无法找回' if phrase is None else
              ('未设置（使用私钥时直接回车）' if phrase == '' else json.dumps(phrase, ensure_ascii=False))))
        print('这是私钥的解锁口令，不是服务器账户的登录密码；显示的外层双引号不属于口令。')
    else:
        print(connection_text(p))


def select_user(deleting=False):
    users = profiles()
    if not users:
        raise Error('尚无本脚本管理的账户。')
    options = {str(i): '{} / 端口 {} / {} / {}'.format(p['name'], p['port'],
               {'key': '密钥登录', 'password': '密码登录', 'both': '密钥加密码'}[p['auth']],
               '运行' if active('ssht-' + p['name']) else '停止') for i, p in enumerate(users, 1)}
    index = choose('选择账户', options)
    p = users[int(index) - 1]
    if p.get('deleting') and not deleting:
        raise Error('此账户删除尚未完成，请从删除菜单继续。')
    try:
        verify_owned(p)
    except Error:
        if not (deleting and p.get('deleting')):
            raise
        try:
            pwd.getpwnam(p['name'])
        except KeyError:
            pass
        else:
            raise
    return p


def modify_user():
    old = select_user()
    p = copy.deepcopy(old)
    mode = choose('修改后将启用并重启该账户服务，断开其现有隧道', {
        '1': '接入端口/监听地址/客户端连接说明', '2': '登录方式/替换公钥/密码',
        '3': '转发权限/目标范围/存活检测/认证次数', '4': 'fail2ban 启停/频率/封禁时间/白名单',
        '5': '重新配置全部项目'})
    with tempfile.TemporaryDirectory(prefix='credentials-', dir=str(ETC)) as td:
        credentials = {}
        if mode in ('1', '5'):
            connection_wizard(p, old)
        if mode in ('2', '5'):
            credentials = auth_wizard(p, Path(td), old)
        if mode in ('3', '5'):
            permissions_wizard(p)
        if mode in ('4', '5'):
            f2b_wizard(p)
        print(profile_summary(p))
        if not yes('确认应用并重启此账户', True):
            return
        dest = prepare_export(p, credentials)
        apply_profile(p, credentials, old)
        complete_export(p, dest)


def delete_user():
    p = select_user(deleting=True)
    name = p['name']
    print('将断开隧道并删除该系统账户、专属配置、jail 和日志。不会删除软件包或导出的凭证。')
    if ask('请输入账户名确认永久删除') != name:
        return
    p['deleting'] = True
    save_json(profile_path(name), p)
    try:
        pwd.getpwnam(name)
        exists = True
    except KeyError:
        exists = False
    if exists:
        verify_owned(p)
        run(['usermod', '-L', name], capture=True)
        stop_user(p)
    service('ssht-' + name, 'disable', False)
    remove_firewall(p)
    jail = jail_path(name)
    if jail.exists():
        old = jail.read_bytes()
        jail.unlink()
        try:
            reload_f2b(name)
        except BaseException:
            atomic(jail, old, 0o644)
            raise Error('fail2ban 清理失败；账户已锁定并停止，配置保留，请修复后重试删除。')
    if exists:
        run(['userdel', name], capture=True)
    # Keep the JSON until last, allowing retries after partial cleanup.
    for path in (ETC / 'sshd' / (name + '.conf'), DATA / 'authorized_keys' / name,
                 service_file(name), Path('/etc/logrotate.d') / ('ssht-' + name),
                 logger_script(name), ETC / 'log-limits' / name, secret_path(name), firewall_script(name)):
        unlink_if_exists(path)
    if (DATA / 'homes' / name).exists():
        shutil.rmtree(str(DATA / 'homes' / name))
    for path in LOG.glob(name + '.log*'):
        path.unlink()
    if OS_ID != 'alpine':
        run(['systemctl', 'daemon-reload'], capture=True)
    profile_path(name).unlink()
    configure_log_limits()
    print('已删除 ' + name + '。导出凭证可能另存多处，请自行清理；旧凭证已不能用于该账户。')


def maintain_user():
    p = select_user()
    mode = choose('账户维护', {'1': '查看配置、连接命令和服务状态', '2': '停止并禁用开机启动',
        '3': '启动并启用开机启动', '4': '重启（断开现有隧道）', '5': '查看最近日志',
        '6': '查看 fail2ban / 解封 IP', '7': '重新导出连接说明和公钥'})
    if mode == '1':
        print(profile_summary(p))
        print(connection_text(p))
        print(service('ssht-' + p['name'], 'status', False).stdout)
    elif mode == '2':
        stop_user(p)
        service('ssht-' + p['name'], 'disable')
        p['enabled'] = False
        save_json(profile_path(p['name']), p)
    elif mode in ('3', '4'):
        prerequisites()
        if p.get('f2b'):
            validate_f2b(p)
        if mode == '4':
            stop_user(p)
        run(['/usr/sbin/sshd', '-t', '-f', ETC / 'sshd' / (p['name'] + '.conf')], capture=True)
        service('ssht-' + p['name'], 'enable')
        service('ssht-' + p['name'], 'start')
        wait_service(p)
        p['enabled'] = True
        save_json(profile_path(p['name']), p)
    elif mode == '5':
        run(['tail', '-n', '80', LOG / (p['name'] + '.log')])
    elif mode == '6':
        if not p.get('f2b'):
            raise Error('本账户未启用 fail2ban。')
        run(['fail2ban-client', 'status', 'ssht-' + p['name']])
        if yes('解封指定 IP'):
            ip = str(ipaddress.ip_address(ask('IP 地址')))
            run(['fail2ban-client', 'set', 'ssht-' + p['name'], 'unbanip', ip])
    elif mode == '7':
        key = DATA / 'authorized_keys' / p['name']
        credentials = {'public': key.read_text() if key.exists() else None}
        print('此处导出公钥和连接说明。已保存的私钥及口令可在主菜单“查看用户”中查看；登录密码无法从账户记录找回。')
        dest = prepare_export(p, credentials)
        complete_export(p, dest)


def main():
    global OS_ID, TTY, LOCK, LIGHT
    if os.geteuid() != 0:
        raise Error('需要 root。')
    args = sys.argv[2:]
    if any(a not in ('--light', '--no-update', '--update') for a in args) or ('--no-update' in args and '--update' in args):
        raise Error('接受 --light、--no-update 或 --update；后两项不能同时使用。')
    os.umask(0o077)
    # Text-mode r+ would require a seekable BufferedRandom stream; terminals are not seekable.
    # Prompts use stdout, and getpass opens its own terminal for secret input.
    TTY = open('/dev/tty', 'r', encoding='utf-8')
    info = {}
    for line in Path('/etc/os-release').read_text().splitlines():
        if '=' in line:
            k, v = line.split('=', 1)
            info[k] = v.strip('"\'')
    OS_ID = info.get('ID')
    if OS_ID not in ('alpine', 'debian', 'ubuntu'):
        raise Error('不支持此发行版。')
    memory, disk = resource_limits()
    LIGHT = '--light' in args or (memory is not None and memory <= 256 * 1024 ** 2) or disk <= 1024 ** 3
    safe_dir('/run/ssht')
    LOCK = open('/run/ssht/manager.lock', 'a')
    try:
        fcntl.flock(LOCK, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as e:
        raise Error('另一个 ssht 管理进程正在运行。') from e
    safe_dir(ETC)
    safe_dir(ETC / 'users')
    leftovers = list(ETC.glob('txn-*'))
    if leftovers:
        raise Error('发现未完成事务，包含恢复清单 manifest.json；请按 README 恢复后再运行：' +
                    ', '.join(str(p) for p in leftovers))
    registration(Path(sys.argv[1]).absolute())
    configure_log_limits()
    menu_banner(info.get('PRETTY_NAME', OS_ID))
    ui_text('修改权限或登录方式会断开该账户的现有连接。', 'warning')
    if LIGHT:
        ui_text('轻量模式：依赖齐全时跳过启动更新；未启用防爆破时关闭连接日志，退出菜单后释放管理进程。', 'muted')
    if '--no-update' not in args and ('--update' in args or not LIGHT or not core_ready()):
        try:
            update_packages()
        except Error as e:
            print('启动包检查未完成：{}\n仍可进入维护菜单；新增需依赖齐全。'.format(e))
    while True:
        try:
            action = choose('sshtunnel · 主菜单', {
                '1': '查看依赖状态', '2': '安装 / 更新依赖',
                '3': '新增用户', '4': '修改用户 · 连接、权限',
                '5': '删除用户', '6': '维护用户 · 启停、日志',
                '7': '日志占用上限', '8': '查看用户 · 密钥、口令', '0': '退出'}, '0',
                sections=[('用户管理', ('3', '8', '4', '6')),
                          ('系统设置', ('1', '2', '7')), ('', ('5', '0'))], danger=('5',))
            if action == '0':
                break
            {'1': package_status, '2': update_packages, '3': create_user,
             '4': modify_user, '5': delete_user, '6': maintain_user, '7': log_settings,
             '8': view_users}[action]()
        except KeyboardInterrupt:
            print()
            ui_text('已取消当前操作。', 'muted')
        except EOFError:
            break
        except (Error, OSError, ValueError, subprocess.SubprocessError) as e:
            print()
            ui_text('操作未完成：' + str(e), 'warning')
        if list(ETC.glob('txn-*')):
            raise Error('仍有未恢复的事务；停止写入，请先按 README 检查恢复清单。')


if __name__ == '__main__':
    try:
        main()
    except (Error, OSError, ValueError, KeyboardInterrupt, EOFError) as e:
        print('\n已停止：' + str(e), file=sys.stderr)
        sys.exit(1)
SSHT_PYTHON
