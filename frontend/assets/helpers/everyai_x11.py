#!/usr/bin/env python3
# Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.
#
# everyai-x11: the Linux counterpart of everyai-ax (macOS), for the `app` tool's desktop windows. Same commands and
# JSON, through Xlib and XTest with ctypes (no packages to install). It works on the display in DISPLAY: a session's
# own headless display (Xvfb, --nested: input there never touches the user's pointer), or the user's X display
# (XWayland apps included). There's no accessibility tree yet: windows are driven by picture and coordinates.
#
#   windows [--pid N]...                         the top-level windows
#   tree --pid N [--window W]                    {"nodes": []} plus the window's frame
#   act ...                                      not available (exit 5)
#   click --pid N --x X --y Y [--count C] [--right] [--front] [--nested]
#   drag --pid N --x X --y Y --to-x X2 --to-y Y2 [--front] [--nested]
#   scroll --pid N --x X --y Y --dy D [--front] [--nested]
#   key --pid N (--text T | --text-stdin | --keyname K) [--mods ctrl,shift,alt,super] [--front] [--nested]
#   raise --pid N [--window W]
#   shot --window ID --out FILE [--nested]       a PNG of the window (on the nested display: with its pop-ups)
#   stream --window ID [--fps F] [--scale S] [--nested]   PNG frames as multipart on stdout
#   trusted                                      {"ax": false, "screen": true}
import ctypes
import ctypes.util
import json
import os
import struct
import sys
import time
import zlib

args = sys.argv[1:]
command = args.pop(0) if args else 'help'


def value(name):
    flag = '--' + name
    return args[args.index(flag) + 1] if flag in args and args.index(flag) + 1 < len(args) else None


def flag(name):
    return ('--' + name) in args


def text_arg():
    # The text to type: from stdin with --text-stdin (a saved password never reaches the process list), else --text.
    if flag('text-stdin'):
        return sys.stdin.buffer.read().decode('utf-8')
    return value('text')


def number(name):
    v = value(name)
    return float(v) if v is not None else None


def emit(obj):
    sys.stdout.write(json.dumps(obj))
    sys.stdout.flush()


def fail(message, code=1):
    sys.stderr.write('error: ' + message + '\n')
    sys.exit(code)


def load(*names):
    for n in names:
        path = ctypes.util.find_library(n)
        for p in ([path] if path else []) + ['lib%s.so.6' % n, 'lib%s.so.1' % n, 'lib%s.so' % n]:
            try:
                return ctypes.cdll.LoadLibrary(p)
            except OSError:
                pass
    return None


X = load('X11')
if X is None:
    fail('libX11 is missing: desktop windows need X11 (XWayland on Wayland desktops)', 3)
XT = load('Xtst')
XRES = load('XRes')

c_ulong, c_long, c_int, c_uint, c_void_p, c_char_p = (ctypes.c_ulong, ctypes.c_long, ctypes.c_int, ctypes.c_uint,
                                                       ctypes.c_void_p, ctypes.c_char_p)
P = ctypes.POINTER


class XWindowAttributes(ctypes.Structure):
    _fields_ = [('x', c_int), ('y', c_int), ('width', c_int), ('height', c_int), ('border_width', c_int),
                ('depth', c_int), ('visual', c_void_p), ('root', c_ulong), ('cls', c_int), ('bit_gravity', c_int),
                ('win_gravity', c_int), ('backing_store', c_int), ('backing_planes', c_ulong),
                ('backing_pixel', c_ulong), ('save_under', c_int), ('colormap', c_ulong),
                ('map_installed', c_int), ('map_state', c_int), ('all_event_masks', c_long),
                ('your_event_mask', c_long), ('do_not_propagate_mask', c_long), ('override_redirect', c_int),
                ('screen', c_void_p)]


class XImageFuncs(ctypes.Structure):
    _fields_ = [(n, c_void_p) for n in ('create_image', 'destroy_image', 'get_pixel', 'put_pixel', 'sub_image',
                                        'add_pixel')]


class XImage(ctypes.Structure):
    _fields_ = [('width', c_int), ('height', c_int), ('xoffset', c_int), ('format', c_int), ('data', c_void_p),
                ('byte_order', c_int), ('bitmap_unit', c_int), ('bitmap_bit_order', c_int), ('bitmap_pad', c_int),
                ('depth', c_int), ('bytes_per_line', c_int), ('bits_per_pixel', c_int), ('red_mask', c_ulong),
                ('green_mask', c_ulong), ('blue_mask', c_ulong), ('obdata', c_void_p), ('f', XImageFuncs)]


class XClientMessageEvent(ctypes.Structure):
    _fields_ = [('type', c_int), ('serial', c_ulong), ('send_event', c_int), ('display', c_void_p),
                ('window', c_ulong), ('message_type', c_ulong), ('format', c_int), ('data', c_long * 5)]


class XEvent(ctypes.Union):
    _fields_ = [('xclient', XClientMessageEvent), ('pad', c_long * 24)]


class XResClientIdSpec(ctypes.Structure):
    _fields_ = [('client', c_ulong), ('mask', c_uint)]


class XResClientIdValue(ctypes.Structure):
    _fields_ = [('spec', XResClientIdSpec), ('length', c_long), ('value', c_void_p)]


X.XOpenDisplay.restype = c_void_p
X.XOpenDisplay.argtypes = [c_char_p]
X.XDefaultRootWindow.restype = c_ulong
X.XDefaultRootWindow.argtypes = [c_void_p]
X.XDefaultScreen.argtypes = [c_void_p]
X.XInternAtom.restype = c_ulong
X.XInternAtom.argtypes = [c_void_p, c_char_p, c_int]
X.XGetWindowProperty.argtypes = [c_void_p, c_ulong, c_ulong, c_long, c_long, c_int, c_ulong, P(c_ulong), P(c_int),
                                 P(c_ulong), P(c_ulong), P(P(ctypes.c_ubyte))]
X.XFree.argtypes = [c_void_p]
X.XQueryTree.argtypes = [c_void_p, c_ulong, P(c_ulong), P(c_ulong), P(P(c_ulong)), P(c_uint)]
X.XGetWindowAttributes.argtypes = [c_void_p, c_ulong, P(XWindowAttributes)]
X.XTranslateCoordinates.argtypes = [c_void_p, c_ulong, c_ulong, c_int, c_int, P(c_int), P(c_int), P(c_ulong)]
X.XGetImage.restype = P(XImage)
X.XGetImage.argtypes = [c_void_p, c_ulong, c_int, c_int, c_uint, c_uint, c_ulong, c_int]
X.XRaiseWindow.argtypes = [c_void_p, c_ulong]
X.XSetInputFocus.argtypes = [c_void_p, c_ulong, c_int, c_ulong]
X.XGetInputFocus.argtypes = [c_void_p, P(c_ulong), P(c_int)]
X.XSendEvent.argtypes = [c_void_p, c_ulong, c_int, c_long, P(XEvent)]
X.XStringToKeysym.restype = c_ulong
X.XStringToKeysym.argtypes = [c_char_p]
X.XKeysymToKeycode.restype = ctypes.c_ubyte
X.XKeysymToKeycode.argtypes = [c_void_p, c_ulong]
X.XGetKeyboardMapping.restype = P(c_ulong)
X.XGetKeyboardMapping.argtypes = [c_void_p, ctypes.c_ubyte, c_int, P(c_int)]
X.XChangeKeyboardMapping.argtypes = [c_void_p, c_int, c_int, P(c_ulong), c_int]
X.XDisplayKeycodes.argtypes = [c_void_p, P(c_int), P(c_int)]
X.XSync.argtypes = [c_void_p, c_int]
X.XFlush.argtypes = [c_void_p]
if XT is not None:
    XT.XTestFakeMotionEvent.argtypes = [c_void_p, c_int, c_int, c_int, c_ulong]
    XT.XTestFakeButtonEvent.argtypes = [c_void_p, c_uint, c_int, c_ulong]
    XT.XTestFakeKeyEvent.argtypes = [c_void_p, c_uint, c_int, c_ulong]
if XRES is not None:
    XRES.XResQueryClientIds.argtypes = [c_void_p, c_long, P(XResClientIdSpec), P(c_long), P(P(XResClientIdValue))]
    XRES.XResClientIdsDestroy.argtypes = [c_long, P(XResClientIdValue)]

# Windows that close while we look at them raise BadWindow: ignore X errors (the calls then return nothing).
ERROR_HANDLER = ctypes.CFUNCTYPE(c_int, c_void_p, c_void_p)(lambda d, e: 0)
X.XSetErrorHandler(ERROR_HANDLER)

D = X.XOpenDisplay(None)
if not D:
    fail('no X display (DISPLAY=%s): desktop windows need X11' % os.environ.get('DISPLAY', ''), 3)
ROOT = X.XDefaultRootWindow(D)


def atom(name):
    return X.XInternAtom(D, name.encode(), 0)


def prop(win, name, kind=0):
    """A property's items: ints for format 32 (CARDINAL, WINDOW, ATOM), bytes for format 8."""
    t, fmt, n, after = c_ulong(), c_int(), c_ulong(), c_ulong()
    data = P(ctypes.c_ubyte)()
    if X.XGetWindowProperty(D, win, atom(name), 0, 1 << 16, 0, kind, ctypes.byref(t), ctypes.byref(fmt),
                            ctypes.byref(n), ctypes.byref(after), ctypes.byref(data)) != 0 or not data:
        return None
    try:
        if fmt.value == 32:
            return list(ctypes.cast(data, P(c_ulong))[:n.value])
        if fmt.value == 8:
            return bytes(data[:n.value])
        return None
    finally:
        X.XFree(data)


def text(win, name):
    raw = prop(win, name)
    return raw.decode('utf-8', 'replace').split('\0')[0] if isinstance(raw, bytes) else ''


def children(win):
    root, parent, kids, n = c_ulong(), c_ulong(), P(c_ulong)(), c_uint()
    if not X.XQueryTree(D, win, ctypes.byref(root), ctypes.byref(parent), ctypes.byref(kids), ctypes.byref(n)):
        return []
    try:
        return [kids[i] for i in range(n.value)]
    finally:
        if kids:
            X.XFree(kids)


def attributes(win):
    a = XWindowAttributes()
    return a if X.XGetWindowAttributes(D, win, ctypes.byref(a)) else None


def frame(win):
    a = attributes(win)
    if a is None:
        return None
    x, y, child = c_int(), c_int(), c_ulong()
    X.XTranslateCoordinates(D, win, ROOT, 0, 0, ctypes.byref(x), ctypes.byref(y), ctypes.byref(child))
    return (x.value, y.value, a.width, a.height, a.map_state == 2, a.override_redirect)


def pid_of(win):
    p = prop(win, '_NET_WM_PID')
    if p:
        return int(p[0])
    if XRES is None:
        return 0
    # The X Resource extension knows the pid of the client that made the window.
    spec = XResClientIdSpec(win, 2)  # XRES_CLIENT_ID_PID_MASK
    n, ids = c_long(), P(XResClientIdValue)()
    if XRES.XResQueryClientIds(D, 1, ctypes.byref(spec), ctypes.byref(n), ctypes.byref(ids)) != 0:
        return 0
    try:
        for i in range(n.value):
            v = ids[i]
            if v.spec.mask & 2 and v.length >= 4 and v.value:
                return ctypes.cast(v.value, P(ctypes.c_uint32))[0]
    finally:
        XRES.XResClientIdsDestroy(n, ids)
    return 0


def client_of(win):
    """The application window inside a window manager's frame (the frame itself has no title or pid)."""
    if prop(win, 'WM_STATE') is not None:
        return win
    for c in children(win):
        if prop(c, 'WM_STATE') is not None:
            return c
    return win


def toplevels(stacking=False):
    """Top-level windows, bottom to top: the window manager's list, else the root's mapped children."""
    listed = prop(ROOT, '_NET_CLIENT_LIST_STACKING' if stacking else '_NET_CLIENT_LIST')
    if listed:
        return list(listed)
    return [client_of(w) for w in children(ROOT)]


def window_info(win):
    f = frame(win)
    if f is None:
        return None
    x, y, w, h, viewable, override = f
    if not viewable or w < 2 or h < 2:
        return None
    wm_class = prop(win, 'WM_CLASS')
    app = wm_class.split(b'\0')[1].decode('utf-8', 'replace') if isinstance(wm_class, bytes) and b'\0' in wm_class \
        else ''
    return {'id': win, 'pid': pid_of(win), 'app': app,
            'title': text(win, '_NET_WM_NAME') or text(win, 'WM_NAME'),
            'x': x, 'y': y, 'w': w, 'h': h, 'popup': bool(override), 'exe': exe_of(pid_of(win))}


def exe_of(pid):
    try:
        return os.readlink('/proc/%d/exe' % pid) if pid else ''
    except OSError:
        return ''


def windows(pids):
    out = []
    for w in reversed(toplevels()):
        info = window_info(w)
        if info is None or info['popup'] or (pids and info['pid'] not in pids):
            continue
        out.append(info)
    return out


def pick(pid, title):
    mine = windows({pid})
    if not mine:
        fail('the app has no window open', 4)
    if title:
        for w in mine:
            if w['title'] == title or str(w['id']) == title:
                return w
        for w in mine:
            if title.lower() in w['title'].lower():
                return w
    return max(mine, key=lambda w: w['w'] * w['h'])


# ---- input

def need_xtest():
    if XT is None:
        fail('libXtst is missing: install it (libxtst6) for clicks and keys on Linux', 3)


def activate(win):
    """Raises [win] and gives it the keyboard: through the window manager when there is one."""
    if prop(ROOT, '_NET_SUPPORTED'):
        ev = XEvent()
        ev.xclient.type = 33  # ClientMessage
        ev.xclient.send_event = 1
        ev.xclient.window = win
        ev.xclient.message_type = atom('_NET_ACTIVE_WINDOW')
        ev.xclient.format = 32
        ev.xclient.data[0] = 2  # from a pager or tool
        X.XSendEvent(D, ROOT, 0, (1 << 20) | (1 << 19), ctypes.byref(ev))
    X.XRaiseWindow(D, win)
    X.XSetInputFocus(D, win, 2, 0)
    X.XSync(D, 0)
    time.sleep(0.08)


def raise_app(pid):
    activate(pick(pid, value('window'))['id'])


def covered(px, py, pid):
    """Where (px, py) is when no window of [pid] (or a pop-up without an owner) is on top there; None when it is."""
    for w in reversed(toplevels(stacking=True)):
        f = frame(w)
        if f is None or not f[4]:
            continue
        x, y, ww, hh = f[:4]
        if not (x <= px < x + ww and y <= py < y + hh):
            continue
        owner = pid_of(w)
        if owner in (0, pid):
            return None
        return "under %s's window" % (window_info(w) or {}).get('app', 'another app')
    return "outside the app's windows"


def guard_pointer(pid, points):
    raise_app(pid)
    if flag('nested'):
        return
    for (px, py) in points:
        where = covered(int(px), int(py), pid)
        if where:
            fail('nothing was sent: that point is %s right now, so a click there would miss the app' % where, 7)


def focus_pid():
    focus, revert = c_ulong(), c_int()
    X.XGetInputFocus(D, ctypes.byref(focus), ctypes.byref(revert))
    w = focus.value
    for _ in range(8):
        if w in (0, 1, ROOT):
            return 0
        p = pid_of(w)
        if p:
            return p
        root, parent, kids, n = c_ulong(), c_ulong(), P(c_ulong)(), c_uint()
        if not X.XQueryTree(D, w, ctypes.byref(root), ctypes.byref(parent), ctypes.byref(kids), ctypes.byref(n)):
            return 0
        if kids:
            X.XFree(kids)
        w = parent.value
    return 0


def guard_keys(pid):
    raise_app(pid)
    if flag('nested'):
        return
    p = focus_pid()
    if p not in (0, pid):
        fail("the app didn't get the keyboard focus, so the keys would go to another app: nothing was sent", 7)


def motion(x, y):
    XT.XTestFakeMotionEvent(D, -1, int(x), int(y), 0)


def button(b, down):
    XT.XTestFakeButtonEvent(D, b, 1 if down else 0, 0)


def click(pid, x, y, count, right):
    need_xtest()
    if flag('front'):
        guard_pointer(pid, [(x, y)])
    motion(x, y)
    for _ in range(max(1, count)):
        button(3 if right else 1, True)
        button(3 if right else 1, False)
        X.XFlush(D)
        time.sleep(0.03)
    X.XSync(D, 0)


def drag(pid, x, y, tx, ty):
    need_xtest()
    if flag('front'):
        guard_pointer(pid, [(x, y), (tx, ty)])
    motion(x, y)
    button(1, True)
    for i in range(1, 17):
        t = i / 16.0
        motion(x + (tx - x) * t, y + (ty - y) * t)
        X.XFlush(D)
        time.sleep(0.016)
    button(1, False)
    X.XSync(D, 0)


def scroll(pid, x, y, dy):
    need_xtest()
    if flag('front'):
        guard_pointer(pid, [(x, y)])
    motion(x, y)
    # One wheel click is about 40 pixels.
    for _ in range(max(1, min(30, int(abs(dy) / 40)))):
        button(5 if dy > 0 else 4, True)
        button(5 if dy > 0 else 4, False)
    X.XSync(D, 0)


KEYNAMES = {
    'enter': 'Return', 'return': 'Return', 'escape': 'Escape', 'esc': 'Escape', 'tab': 'Tab', 'space': 'space',
    'backspace': 'BackSpace', 'delete': 'Delete', 'home': 'Home', 'end': 'End', 'pageup': 'Prior',
    'pagedown': 'Next', 'up': 'Up', 'down': 'Down', 'left': 'Left', 'right': 'Right', 'arrowup': 'Up',
    'arrowdown': 'Down', 'arrowleft': 'Left', 'arrowright': 'Right', 'menu': 'Menu',
}
MODS = {'ctrl': 'Control_L', 'control': 'Control_L', 'cmd': 'Control_L', 'command': 'Control_L', 'shift': 'Shift_L',
        'alt': 'Alt_L', 'option': 'Alt_L', 'super': 'Super_L', 'meta': 'Super_L'}


def keysym_of(name):
    if name.lower() in KEYNAMES:
        name = KEYNAMES[name.lower()]
    elif len(name) == 2 and name[0] in 'fF' and name[1:].isdigit() or len(name) == 3 and name[0] in 'fF':
        name = name.upper()
    ks = X.XStringToKeysym(name.encode())
    return ks


def keysym_of_char(ch):
    o = ord(ch)
    if ch == '\n':
        return X.XStringToKeysym(b'Return')
    if ch == '\t':
        return X.XStringToKeysym(b'Tab')
    return o if 0x20 <= o <= 0x7e or 0xa0 <= o <= 0xff else 0x01000000 + o


class Keymap:
    """Keycodes for keysyms, borrowing an unused keycode for characters the keyboard map lacks (like xdotool)."""

    def __init__(self):
        lo, hi = c_int(), c_int()
        X.XDisplayKeycodes(D, ctypes.byref(lo), ctypes.byref(hi))
        self.lo, self.hi = lo.value, hi.value
        per = c_int()
        syms = X.XGetKeyboardMapping(D, self.lo, self.hi - self.lo + 1, ctypes.byref(per))
        self.per = per.value
        self.map = {}
        self.spare = None
        for i in range(self.hi - self.lo + 1):
            row = [syms[i * self.per + j] for j in range(self.per)]
            if not any(row) and self.spare is None:
                self.spare = self.lo + i
            for j, s in enumerate(row[:2]):
                if s and s not in self.map:
                    self.map[s] = (self.lo + i, j == 1)
        X.XFree(syms)
        self.borrowed = False

    def code(self, keysym):
        if keysym in self.map:
            return self.map[keysym]
        if self.spare is None:
            return None
        row = (c_ulong * self.per)(*([keysym, keysym] + [0] * (self.per - 2)))
        X.XChangeKeyboardMapping(D, self.spare, self.per, row, 1)
        X.XSync(D, 0)
        time.sleep(0.02)
        self.borrowed = True
        return (self.spare, False)

    def restore(self):
        if self.borrowed and self.spare is not None:
            row = (c_ulong * self.per)(*([0] * self.per))
            X.XChangeKeyboardMapping(D, self.spare, self.per, row, 1)
            X.XSync(D, 0)


def tap_key(code, shift, mods=()):
    shift_code = X.XKeysymToKeycode(D, X.XStringToKeysym(b'Shift_L'))
    held = [X.XKeysymToKeycode(D, X.XStringToKeysym(m.encode())) for m in mods]
    if shift:
        held.append(shift_code)
    for c in held:
        XT.XTestFakeKeyEvent(D, c, 1, 0)
    XT.XTestFakeKeyEvent(D, code, 1, 0)
    XT.XTestFakeKeyEvent(D, code, 0, 0)
    for c in reversed(held):
        XT.XTestFakeKeyEvent(D, c, 0, 0)
    X.XFlush(D)
    time.sleep(0.008)


def key(pid, txt, name, mods):
    need_xtest()
    if flag('front'):
        guard_keys(pid)
    km = Keymap()
    try:
        modnames = [MODS[m.strip().lower()] for m in (mods or '').split(',') if m.strip().lower() in MODS]
        if name is not None:
            ks = keysym_of(name)
            got = km.code(ks) if ks else None
            if got is None:
                fail('unknown key "%s"' % name, 2)
            tap_key(got[0], got[1], modnames)
            return
        for ch in txt or '':
            got = km.code(keysym_of_char(ch))
            if got is not None:
                tap_key(got[0], got[1], modnames)
        X.XSync(D, 0)
    finally:
        km.restore()


# ---- pictures

def grab(win_id, nested):
    """The window as (width, height, BGRA bytes): on the nested display the screen's pixels there (pop-ups
    included); on the user's display the window's own pixels."""
    f = frame(win_id)
    if f is None:
        fail('no window %s' % win_id, 4)
    x, y, w, h = f[:4]
    src, sx, sy = (ROOT, x, y) if nested else (win_id, 0, 0)
    img = X.XGetImage(D, src, sx, sy, w, h, 0xffffffff, 2)  # ZPixmap
    if not img:
        fail("the window's picture couldn't be read", 5)
    try:
        im = img.contents
        if im.bits_per_pixel != 32:
            fail('unsupported %d-bit display' % im.bits_per_pixel, 5)
        stride = im.bytes_per_line
        raw = ctypes.string_at(im.data, stride * im.height)
        return im.width, im.height, stride, raw
    finally:
        destroy = ctypes.CFUNCTYPE(c_int, c_void_p)(img.contents.f.destroy_image)
        destroy(ctypes.cast(img, c_void_p))


def png(width, height, stride, raw, step=1):
    """BGRA rows as an RGB PNG, every [step]th pixel and row."""
    w, h = (width + step - 1) // step, (height + step - 1) // step
    rows = []
    for yy in range(0, height, step):
        line = raw[yy * stride: yy * stride + width * 4]
        if step > 1:
            line = b''.join(line[i:i + 4] for i in range(0, len(line), 4 * step))
        rgb = bytearray(w * 3)
        rgb[0::3] = line[2::4][:w]
        rgb[1::3] = line[1::4][:w]
        rgb[2::3] = line[0::4][:w]
        rows.append(b'\0' + bytes(rgb))

    def chunk(kind, data):
        c = struct.pack('>I', len(data)) + kind + data
        return c + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)

    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) +
            chunk(b'IDAT', zlib.compress(b''.join(rows), 1)) + chunk(b'IEND', b''))


def shot(win_id, out):
    w, h, stride, raw = grab(win_id, flag('nested'))
    with open(out, 'wb') as f:
        f.write(png(w, h, stride, raw))
    emit({'ok': True, 'width': w, 'height': h})


def stream(win_id, fps, scale):
    step = max(1, int(round(1 / scale))) if scale > 0 else 2
    out = sys.stdout.buffer
    while True:
        t = time.time()
        w, h, stride, raw = grab(win_id, flag('nested'))
        data = png(w, h, stride, raw, step)
        try:
            out.write(b'--everyaiframe\r\nContent-Type: image/png\r\nContent-Length: %d\r\n\r\n' % len(data))
            out.write(data + b'\r\n')
            out.flush()
        except (BrokenPipeError, OSError):
            # The reader went away: leave quietly (Python would complain flushing stdout at exit).
            os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
            return
        time.sleep(max(0.0, 1.0 / max(1.0, fps) - (time.time() - t)))


# ---- main

def need_pid():
    p = value('pid')
    if p is None or not p.isdigit():
        fail('--pid is needed')
    return int(p)


if command == 'trusted':
    emit({'ax': False, 'screen': True})
elif command == 'windows':
    pids = {int(args[i + 1]) for i, a in enumerate(args) if a == '--pid' and i + 1 < len(args)}
    emit(windows(pids))
elif command == 'tree':
    w = pick(need_pid(), value('window'))
    emit({'nodes': [], 'window': 0, 'x': w['x'], 'y': w['y'], 'w': w['w'], 'h': w['h'], 'title': w['title']})
elif command == 'act':
    fail('accessibility actions are not available on Linux yet', 5)
elif command == 'click':
    if number('x') is None or number('y') is None:
        fail('click needs --x and --y')
    click(need_pid(), number('x'), number('y'), int(number('count') or 1), flag('right'))
    emit({'ok': True})
elif command == 'drag':
    if None in (number('x'), number('y'), number('to-x'), number('to-y')):
        fail('drag needs --x, --y, --to-x and --to-y')
    drag(need_pid(), number('x'), number('y'), number('to-x'), number('to-y'))
    emit({'ok': True})
elif command == 'scroll':
    if None in (number('x'), number('y'), number('dy')):
        fail('scroll needs --x, --y and --dy')
    scroll(need_pid(), number('x'), number('y'), number('dy'))
    emit({'ok': True})
elif command == 'key':
    key(need_pid(), text_arg(), value('keyname'), value('mods'))
    emit({'ok': True})
elif command == 'raise':
    raise_app(need_pid())
    emit({'ok': True})
elif command == 'shot':
    if value('window') is None or value('out') is None:
        fail('shot needs --window and --out')
    shot(int(value('window')), value('out'))
elif command == 'stream':
    if value('window') is None:
        fail('stream needs --window')
    stream(int(value('window')), number('fps') or 4, number('scale') or 0.5)
else:
    sys.stderr.write('usage: everyai-x11 windows|tree|click|drag|scroll|key|raise|shot|stream|trusted …\n')
    sys.exit(2)
