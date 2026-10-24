import urllib.request, json, socket, base64, os

pages = json.loads(urllib.request.urlopen('http://127.0.0.1:9222/json').read().decode())
ws_url = None
for p in pages:
    if p.get('type') == 'page' and 'webSocketDebuggerUrl' in p:
        ws_url = p['webSocketDebuggerUrl']
        break

if not ws_url:
    print('No WS URL')
    exit(1)

host_port = ws_url.split('//')[1].split('/')[0]
path = '/' + '/'.join(ws_url.split('//')[1].split('/')[1:])
host, port = host_port.split(':')

s = socket.create_connection((host, int(port)), timeout=3)
sec_key = base64.b64encode(os.urandom(16)).decode()
handshake = f"GET {path} HTTP/1.1\r\nHost: {host_port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {sec_key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
s.sendall(handshake.encode())

hdr_data = b''
while b'\r\n\r\n' not in hdr_data:
    hdr_data += s.recv(512)

def send_cdp(m):
    data = json.dumps(m).encode()
    length = len(data)
    frame = bytearray([0x81])
    if length < 126:
        frame.append(0x80 | length)
    elif length < 65536:
        frame.append(0x80 | 126)
        frame.extend(length.to_bytes(2, "big"))
    mask = os.urandom(4)
    frame.extend(mask)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
    frame.extend(masked)
    s.sendall(frame)

inject_js = """
(function() {
    function deepPurge(root) {
        const css = `
            ha-menu-button,
            ha-sidebar,
            #drawer,
            ha-drawer,
            .mdc-drawer,
            [slot="navigationIcon"],
            ha-icon-button[aria-label="Menu"],
            ha-icon-button[aria-label="Sidebar"],
            ha-icon-button[title="Menu"],
            ha-icon-button[title="Sidebar"],
            [data-panel="profile"],
            mwc-icon-button[slot="navigationIcon"],
            ha-top-app-bar-fixed ha-menu-button,
            app-header ha-menu-button {
                display: none !important;
                visibility: hidden !important;
                width: 0 !important;
                max-width: 0 !important;
                height: 0 !important;
                pointer-events: none !important;
                opacity: 0 !important;
            }
        `;
        if (!root.querySelector('#kiosk-force-hide-sandwich')) {
            const style = document.createElement('style');
            style.id = 'kiosk-force-hide-sandwich';
            style.textContent = css;
            (root.head || root).appendChild(style);
        }

        const buttons = root.querySelectorAll('ha-menu-button, [slot="navigationIcon"], ha-icon-button[aria-label="Menu"], ha-icon-button[aria-label="Sidebar"]');
        buttons.forEach(b => {
            b.style.setProperty('display', 'none', 'important');
            b.style.setProperty('visibility', 'hidden', 'important');
            b.style.setProperty('width', '0', 'important');
            b.style.setProperty('height', '0', 'important');
            try { b.remove(); } catch(e) {}
        });

        const all = root.querySelectorAll('*');
        for (let i = 0; i < all.length; i++) {
            if (all[i].shadowRoot) {
                deepPurge(all[i].shadowRoot);
            }
        }
    }

    deepPurge(document);
    if (!window.__kiosk_purge_loop_active) {
        window.__kiosk_purge_loop_active = true;
        setInterval(() => deepPurge(document), 400);
    }
    return 'PURGED_SUCCESSFULLY';
})()
"""

send_cdp({'id': 100, 'method': 'Runtime.evaluate', 'params': {'expression': inject_js, 'returnByValue': True}})
print('Command sent!')
s.close()
