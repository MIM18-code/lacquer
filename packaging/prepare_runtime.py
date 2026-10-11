#!/usr/bin/env python3
"""Build the pinned, minimal tool runtime (ffmpeg, ffprobe, tsMuxeR) for the app.

Downloads the sources named in runtime-sources.json into packaging/vendor/,
checks every SHA-256, builds zimg, x264 and FFmpeg as static arm64 code, adds
the upstream tsMuxeR binary, asserts that every codec, filter and format the
app needs is present, and writes the result to packaging/vendor/runtime/:

    runtime/bin/{ffmpeg,ffprobe,tsMuxeR}
    runtime/legal/...            license texts, exact configure lines, build notes
    runtime/MANIFEST.json        SHA-256 of every file

Usage:
    prepare_runtime.py                 build (skips if the runtime is current)
    prepare_runtime.py --force         rebuild from scratch
    prepare_runtime.py --fetch-only    download and verify sources only
    prepare_runtime.py --emit-sources DIR
                                       copy the pinned source archives to DIR
                                       (GPL corresponding source for releases)

Long build: run it in the background. Logs land in packaging/vendor/build/logs/.
"""
import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import time
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PKG = ROOT / 'packaging'
VENDOR = PKG / 'vendor'
SOURCES_JSON = PKG / 'runtime-sources.json'
RUNTIME = VENDOR / 'runtime'
# autotools and FFmpeg's configure break on spaces in paths, and this repo lives
# in a folder with spaces, so the build tree sits in a space-free cache folder.
# Override with RUNTIME_BUILD_DIR. Logs are copied back to vendor/build-logs/.
BUILD = Path(os.environ.get('RUNTIME_BUILD_DIR') or (Path.home() / 'Library/Caches/lacquer-runtime-build'))
PREFIX = BUILD / 'prefix'
LOGS = BUILD / 'logs'

# What the app needs from the bundled ffmpeg. The build fails if any is missing.
REQUIRED = {
    'decoders': [
        # video masters
        'prores', 'dnxhd', 'h264', 'hevc', 'mpeg2video', 'mjpeg',
        # audio in MOV / MP4 / MXF / MKV
        'pcm_s16le', 'pcm_s16be', 'pcm_s24le', 'pcm_s24be', 'pcm_s32le',
        'pcm_s32be', 'pcm_f32le', 'pcm_f32be', 'pcm_f64le', 'pcm_f64be',
        'aac', 'ac3', 'eac3', 'alac', 'mp3', 'flac',
    ],
    'encoders': ['libx264', 'ac3', 'prores_ks', 'pcm_s24le'],
    'filters': [
        'bwdif', 'scale', 'pad', 'setsar', 'interlace', 'setfield', 'format',
        'amerge', 'join', 'pan', 'aresample', 'zscale', 'tonemap',
        'colorspace', 'fps', 'aformat', 'anull', 'null',
        'testsrc2', 'sine',
    ],
    'demuxers': ['mov', 'mxf', 'matroska', 'wav', 'mpegts', 'ac3', 'aiff'],
    'devices': ['lavfi'],  # -f lavfi test sources, listed by -devices
    'muxers': ['h264', 'ac3', 'wav', 'mov', 'matroska', 'null'],
    'hwaccels': ['videotoolbox'],
}


def say(msg):
    print(msg, flush=True)


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def read_env_file():
    """Parse packaging/app.env (KEY="value" lines)."""
    out = {}
    for line in (PKG / 'app.env').read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, _, value = line.partition('=')
        out[key.strip()] = value.strip().strip('"').strip("'")
    return out


def load_sources():
    return json.loads(SOURCES_JSON.read_text())


def fetch(entry):
    """Download if missing, then verify. Never trusts a file with a wrong hash."""
    path = VENDOR / entry['file']
    if not path.exists():
        say('downloading %s' % entry['url'])
        tmp = path.with_name(path.name + '.download')
        req = urllib.request.Request(entry['url'], headers={'User-Agent': 'lacquer-build'})
        with urllib.request.urlopen(req, timeout=120) as src, open(tmp, 'wb') as dst:
            shutil.copyfileobj(src, dst)
        got = sha256(tmp)
        if got != entry['sha256']:
            tmp.unlink()
            raise SystemExit('HASH MISMATCH for download %s\n  got  %s\n  want %s' % (entry['file'], got, entry['sha256']))
        tmp.rename(path)
    got = sha256(path)
    if got != entry['sha256']:
        raise SystemExit('HASH MISMATCH for %s\n  got  %s\n  want %s\nDelete it to re-download, or fix runtime-sources.json deliberately.' % (path, got, entry['sha256']))
    return path


def run(cmd, cwd, log, env):
    """Run a command, appending output to a log file; show the tail on failure."""
    LOGS.mkdir(parents=True, exist_ok=True)
    with open(LOGS / log, 'ab') as f:
        f.write(('\n$ %s\n' % ' '.join(map(str, cmd))).encode())
        f.flush()
        proc = subprocess.run(cmd, cwd=str(cwd), env=env, stdout=f, stderr=subprocess.STDOUT)
    if proc.returncode != 0:
        tail = (LOGS / log).read_text(errors='replace').splitlines()[-40:]
        raise SystemExit('FAILED: %s (see %s)\n%s' % (' '.join(map(str, cmd)), LOGS / log, '\n'.join(tail)))


def extract_tar(archive, dest):
    dest.mkdir(parents=True)
    # --strip-components so every source tree lands directly in dest
    subprocess.run(['tar', '-xf', str(archive), '-C', str(dest), '--strip-components', '1'], check=True)


def build_env(min_macos):
    if ' ' in str(BUILD):
        raise SystemExit('Build directory must not contain spaces: %s' % BUILD)
    env = {
        'PATH': '/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin',
        'HOME': os.environ.get('HOME', ''),
        'LANG': 'C',
        'MACOSX_DEPLOYMENT_TARGET': min_macos,
        # Only our own prefix: a Homebrew x264.pc or zimg.pc must never leak in.
        'PKG_CONFIG_LIBDIR': str(PREFIX / 'lib/pkgconfig'),
        'PKG_CONFIG_PATH': '',
        'LIBTOOLIZE': 'glibtoolize',
        'CC': 'clang',
        'CXX': 'clang++',
        'SDKROOT': subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip(),
    }
    return env


def stamp_value(min_macos):
    h = hashlib.sha256()
    h.update(SOURCES_JSON.read_bytes())
    h.update(Path(__file__).read_bytes())
    h.update(min_macos.encode())
    return h.hexdigest()


def build_all(sources, inputs, min_macos):
    env = build_env(min_macos)
    jobs = str(os.cpu_count() or 4)
    common_cflags = '-O2 -mmacosx-version-min=%s -ffile-prefix-map=%s=.' % (min_macos, BUILD)
    lines = {}  # name -> exact configure line, kept for the legal folder

    if BUILD.exists():
        shutil.rmtree(BUILD)
    LOGS.mkdir(parents=True)
    PREFIX.mkdir(parents=True)

    # ---- zimg (needs autoconf, automake, libtool: brew install autoconf automake libtool)
    say('== zimg')
    zsrc = BUILD / 'zimg'
    extract_tar(inputs['zimg'], zsrc)
    cfg = ['./configure', '--prefix=%s' % PREFIX, '--enable-static', '--disable-shared',
           '--disable-testapp', '--disable-example', '--disable-unit-test',
           'CFLAGS=%s' % common_cflags, 'CXXFLAGS=%s' % common_cflags,
           'LDFLAGS=-mmacosx-version-min=%s' % min_macos]
    run(['./autogen.sh'], zsrc, 'zimg.log', env)
    run(cfg, zsrc, 'zimg.log', env)
    run(['make', '-j', jobs], zsrc, 'zimg.log', env)
    run(['make', 'install'], zsrc, 'zimg.log', env)
    lines['zimg'] = ' '.join(['./autogen.sh &&'] + cfg)

    # ---- x264
    say('== x264')
    xsrc = BUILD / 'x264'
    extract_tar(inputs['x264'], xsrc)
    cfg = ['./configure', '--prefix=%s' % PREFIX, '--enable-static', '--disable-cli',
           '--enable-pic', '--disable-opencl',
           '--extra-cflags=%s' % common_cflags,
           '--extra-ldflags=-mmacosx-version-min=%s' % min_macos]
    run(cfg, xsrc, 'x264.log', env)
    run(['make', '-j', jobs], xsrc, 'x264.log', env)
    run(['make', 'install'], xsrc, 'x264.log', env)
    lines['x264'] = ' '.join(cfg)

    # ---- ffmpeg
    say('== ffmpeg (slow)')
    fsrc = BUILD / 'ffmpeg'
    extract_tar(inputs['ffmpeg'], fsrc)
    cfg = ['./configure', '--prefix=%s' % PREFIX,
           '--cc=clang', '--arch=arm64',
           '--enable-static', '--disable-shared',
           '--disable-autodetect',
           '--enable-gpl', '--enable-version3',
           '--enable-libx264', '--enable-libzimg',
           '--enable-videotoolbox', '--enable-audiotoolbox',
           '--enable-zlib', '--enable-bzlib', '--enable-iconv',
           '--disable-network', '--disable-doc', '--disable-ffplay', '--disable-debug',
           '--pkg-config=/opt/homebrew/bin/pkg-config', '--pkg-config-flags=--static',
           '--extra-cflags=%s -I%s/include' % (common_cflags, PREFIX),
           '--extra-ldflags=-mmacosx-version-min=%s -L%s/lib' % (min_macos, PREFIX),
           '--extra-libs=-lc++ -liconv']
    run(cfg, fsrc, 'ffmpeg.log', env)
    run(['make', '-j', jobs, 'ffmpeg', 'ffprobe'], fsrc, 'ffmpeg.log', env)
    lines['ffmpeg'] = ' '.join(cfg)
    return lines, {'zimg': zsrc, 'x264': xsrc, 'ffmpeg': fsrc}


def parse_names(output, comma=False):
    names = set()
    seen_sep = False
    for line in output.splitlines():
        if not seen_sep:
            if line.strip().startswith('---'):
                seen_sep = True
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        if comma:
            names.update(parts[1].split(','))
        else:
            names.add(parts[1])
    return names


def ff(binary, *args):
    return subprocess.check_output([str(binary), '-hide_banner'] + list(args), text=True, stderr=subprocess.STDOUT)


def check_linkage(path):
    out = subprocess.check_output(['otool', '-L', str(path)], text=True)
    bad = [l.strip() for l in out.splitlines()[1:]
           if not l.strip().startswith(('/usr/lib/', '/System/Library/'))]
    if bad:
        raise SystemExit('%s links outside /usr/lib and /System:\n  %s' % (path.name, '\n  '.join(bad)))
    archs = subprocess.check_output(['lipo', '-archs', str(path)], text=True).strip()
    if archs != 'arm64':
        raise SystemExit('%s is not thin arm64: %s' % (path.name, archs))


def verify(bin_dir):
    ffmpeg = bin_dir / 'ffmpeg'
    for name in ('ffmpeg', 'ffprobe', 'tsMuxeR'):
        check_linkage(bin_dir / name)
    version = ff(ffmpeg, '-version')
    for token in ('--enable-gpl', '--enable-version3', '--enable-libx264', '--enable-libzimg'):
        if token not in version:
            raise SystemExit('ffmpeg configuration is missing %s' % token)
    for banned in ('--enable-nonfree', '--enable-openssl', '--enable-libx265', '--enable-libfreetype',
                   '--enable-libmp3lame', '--enable-libopus', '--enable-libvpx', '--enable-libaom'):
        if banned in version:
            raise SystemExit('ffmpeg configuration has unexpected %s' % banned)
    got = {
        'decoders': parse_names(ff(ffmpeg, '-decoders')),
        'encoders': parse_names(ff(ffmpeg, '-encoders')),
        'filters': parse_names(ff(ffmpeg, '-filters')),
        'demuxers': parse_names(ff(ffmpeg, '-demuxers'), comma=True),
        'muxers': parse_names(ff(ffmpeg, '-muxers'), comma=True),
        'devices': parse_names(ff(ffmpeg, '-devices'), comma=True),
    }
    hw = ff(ffmpeg, '-hwaccels').split()
    got['hwaccels'] = set(hw)
    report = []
    missing = []
    for kind, wanted in REQUIRED.items():
        for name in wanted:
            if name not in got[kind]:
                missing.append('%s:%s' % (kind, name))
        report.append('%s: %s' % (kind, ' '.join(wanted)))
    if missing:
        raise SystemExit('Required components missing from ffmpeg: ' + ', '.join(missing))
    # ffprobe must come from the same build
    pv = ff(bin_dir / 'ffprobe', '-version').splitlines()[0]
    fv = version.splitlines()[0]
    if pv.split()[2] != fv.split()[2]:
        raise SystemExit('ffprobe/ffmpeg version mismatch: %s vs %s' % (pv, fv))
    return report, fv


def build_runtime(args):
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise SystemExit('This recipe needs Apple Silicon macOS.')
    VENDOR.mkdir(parents=True, exist_ok=True)
    sources = load_sources()
    inputs = {name: fetch(entry) for name, entry in sources.items()}
    if args.fetch_only:
        say('sources verified')
        return
    env = read_env_file()
    min_macos = env.get('MIN_MACOS', '13.0')
    stamp = stamp_value(min_macos)
    if not args.force and (RUNTIME / 'STAMP').exists() and (RUNTIME / 'STAMP').read_text().strip() == stamp:
        say('runtime is current: %s (use --force to rebuild)' % RUNTIME)
        return

    t0 = time.time()
    lines, trees = build_all(sources, inputs, min_macos)

    if RUNTIME.exists():
        shutil.rmtree(RUNTIME)
    bin_dir = RUNTIME / 'bin'
    legal = RUNTIME / 'legal'
    bin_dir.mkdir(parents=True)
    legal.mkdir()

    for name in ('ffmpeg', 'ffprobe'):
        shutil.copy2(trees['ffmpeg'] / name, bin_dir / name)
    # tsMuxeR: upstream release binary, unmodified
    with zipfile.ZipFile(inputs['tsmuxer']) as z:
        names = [n for n in z.namelist() if n.split('/')[-1] == 'tsMuxeR' and not n.endswith('/')]
        if len(names) != 1:
            raise SystemExit('unexpected tsMuxeR zip layout: %s' % z.namelist())
        (bin_dir / 'tsMuxeR').write_bytes(z.read(names[0]))
    for name in ('ffmpeg', 'ffprobe', 'tsMuxeR'):
        os.chmod(bin_dir / name, 0o755)
    # Strip local symbols from the ones we built (tsMuxeR stays byte-identical to upstream).
    for name in ('ffmpeg', 'ffprobe'):
        subprocess.run(['strip', '-x', str(bin_dir / name)], check=True)
    subprocess.run(['xattr', '-cr', str(bin_dir)], check=False)
    # Strip invalidates the linker signature; arm64 needs one to run at all. Ad-hoc for
    # now; make_dmg.sh re-signs with the Developer ID.
    for name in ('ffmpeg', 'ffprobe'):
        subprocess.run(['codesign', '--force', '-s', '-', str(bin_dir / name)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    say('== verifying')
    report, ffver = verify(bin_dir)

    # ---- legal folder
    ffl = legal / 'ffmpeg'
    ffl.mkdir()
    for name in ('COPYING.GPLv3', 'COPYING.GPLv2', 'COPYING.LGPLv3', 'COPYING.LGPLv2.1', 'LICENSE.md', 'CREDITS'):
        if (trees['ffmpeg'] / name).exists():
            shutil.copy2(trees['ffmpeg'] / name, ffl / name)
    (ffl / 'buildconf.txt').write_text(ff(bin_dir / 'ffmpeg', '-buildconf'))
    xl = legal / 'x264'
    xl.mkdir()
    shutil.copy2(trees['x264'] / 'COPYING', xl / 'COPYING')
    zl = legal / 'zimg'
    zl.mkdir()
    shutil.copy2(trees['zimg'] / 'COPYING', zl / 'COPYING')
    tl = legal / 'tsMuxer'
    tl.mkdir()
    with tarfile.open(inputs['tsmuxer_source']) as t:
        member = next(m for m in t.getmembers() if m.name.count('/') == 1 and m.name.endswith('/LICENSE'))
        (tl / 'LICENSE').write_bytes(t.extractfile(member).read())

    xcode = subprocess.check_output(['xcodebuild', '-version'], text=True).replace('\n', ' ').strip()
    clang = subprocess.check_output(['clang', '--version'], text=True).splitlines()[0]
    sw = subprocess.check_output(['sw_vers'], text=True).replace('\n', '; ')
    build_txt = ['Build record for the bundled command-line tools', '',
                 'Built: %s' % time.strftime('%Y-%m-%d %H:%M:%S %z'),
                 'Host: %s' % sw, 'Xcode: %s' % xcode, 'Compiler: %s' % clang,
                 'Deployment target: macOS %s, arm64 only' % min_macos, '',
                 'Source archives (SHA-256 verified before use):']
    for name, e in sources.items():
        build_txt.append('  %-15s %s  %s' % (name, e['sha256'], e['url']))
    build_txt += ['', 'Exact configure lines (build order: zimg, x264, ffmpeg):', '']
    for name in ('zimg', 'x264', 'ffmpeg'):
        build_txt += ['[%s]' % name, lines[name], '']
    build_txt += ['ffmpeg -version:', ffver, '',
                  'Verified present in ffmpeg:'] + ['  ' + r for r in report] + [
                  '', 'tsMuxeR is the unmodified upstream 2.7.0 macOS arm64 release binary.',
                  'To rebuild: python3 packaging/prepare_runtime.py --force']
    (legal / 'BUILD.txt').write_text('\n'.join(build_txt) + '\n')
    shutil.copy2(SOURCES_JSON, legal / 'runtime-sources.json')
    shutil.copy2(Path(__file__), legal / 'prepare_runtime.py')

    manifest = {}
    for p in sorted(RUNTIME.rglob('*')):
        if p.is_file() and p.name != 'MANIFEST.json':
            manifest[p.relative_to(RUNTIME).as_posix()] = sha256(p)
    (RUNTIME / 'MANIFEST.json').write_text(json.dumps(manifest, indent=2) + '\n')
    (RUNTIME / 'STAMP').write_text(stamp + '\n')
    shutil.rmtree(VENDOR / 'build-logs', ignore_errors=True)
    shutil.copytree(LOGS, VENDOR / 'build-logs')
    say('runtime ready in %.0f s: %s' % (time.time() - t0, RUNTIME))


def emit_sources(dest):
    dest = Path(dest)
    dest.mkdir(parents=True, exist_ok=True)
    sources = load_sources()
    for entry in sources.values():
        shutil.copy2(fetch(entry), dest / entry['file'])
    asc = VENDOR / 'ffmpeg-9.0.2.tar.xz.asc'
    if asc.exists():
        shutil.copy2(asc, dest)
    shutil.copy2(SOURCES_JSON, dest)
    shutil.copy2(Path(__file__), dest)
    say('source archives written to %s' % dest)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--force', action='store_true')
    p.add_argument('--fetch-only', action='store_true')
    p.add_argument('--emit-sources', metavar='DIR')
    args = p.parse_args()
    if args.emit_sources:
        emit_sources(args.emit_sources)
    else:
        build_runtime(args)


if __name__ == '__main__':
    main()
