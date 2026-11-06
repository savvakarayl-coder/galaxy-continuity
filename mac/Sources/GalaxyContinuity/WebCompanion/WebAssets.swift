import Foundation

public enum WebAssets {
    public static let html: String = """
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <meta name="theme-color" content="#0d1117">
    <title>Galaxy Continuity</title>
    <link rel="icon" href="data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 100 100%22><text y=%22.9em%22 font-size=%2290%22>⚡</text></svg>">
    <style>
        :root {
            --bg-color: #0b0f19;
            --card-bg: rgba(22, 27, 44, 0.7);
            --card-border: rgba(255, 255, 255, 0.08);
            --accent: #2563eb;
            --accent-glow: #3b82f6;
            --galaxy-blue: #0381fe;
            --text-primary: #f8fafc;
            --text-secondary: #94a3b8;
            --success: #10b981;
            --danger: #ef4444;
            --font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
        }

        * {
            box-sizing: border-box;
            margin: 0;
            padding: 0;
            -webkit-tap-highlight-color: transparent;
        }

        body {
            font-family: var(--font-family);
            background-color: var(--bg-color);
            color: var(--text-primary);
            min-height: 100vh;
            padding: 16px;
            display: flex;
            flex-direction: column;
            align-items: center;
            overflow-x: hidden;
            background-image: radial-gradient(circle at 50% 0%, rgba(3, 129, 254, 0.15), transparent 70%);
        }

        .container {
            width: 100%;
            max-width: 480px;
            display: flex;
            flex-direction: column;
            gap: 16px;
        }

        /* Header */
        header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 12px 16px;
            background: var(--card-bg);
            border: 1px solid var(--card-border);
            border-radius: 20px;
            backdrop-filter: blur(12px);
        }

        .brand {
            display: flex;
            align-items: center;
            gap: 10px;
        }

        .brand-icon {
            width: 36px;
            height: 36px;
            background: linear-gradient(135deg, #0381fe, #7928ca);
            border-radius: 10px;
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 20px;
            box-shadow: 0 4px 12px rgba(3, 129, 254, 0.3);
        }

        .brand-title {
            font-size: 16px;
            font-weight: 700;
            letter-spacing: -0.3px;
        }

        .brand-subtitle {
            font-size: 11px;
            color: var(--text-secondary);
        }

        .status-pill {
            display: flex;
            align-items: center;
            gap: 6px;
            padding: 6px 12px;
            border-radius: 20px;
            font-size: 12px;
            font-weight: 600;
            background: rgba(255, 255, 255, 0.05);
            border: 1px solid var(--card-border);
        }

        .status-dot {
            width: 8px;
            height: 8px;
            border-radius: 50%;
            background: var(--danger);
        }

        .status-dot.connected {
            background: var(--success);
            box-shadow: 0 0 8px var(--success);
        }

        /* Cards */
        .card {
            background: var(--card-bg);
            border: 1px solid var(--card-border);
            border-radius: 20px;
            padding: 18px;
            backdrop-filter: blur(12px);
            display: flex;
            flex-direction: column;
            gap: 14px;
        }

        .card-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
        }

        .card-title {
            font-size: 15px;
            font-weight: 700;
            display: flex;
            align-items: center;
            gap: 8px;
        }

        .badge {
            font-size: 11px;
            padding: 3px 8px;
            border-radius: 12px;
            background: rgba(3, 129, 254, 0.2);
            color: #60a5fa;
            font-weight: 600;
        }

        /* Clipboard */
        .clip-box {
            background: rgba(0, 0, 0, 0.3);
            border: 1px solid rgba(255, 255, 255, 0.06);
            border-radius: 14px;
            padding: 12px 14px;
            font-size: 13px;
            line-height: 1.5;
            color: #e2e8f0;
            word-break: break-word;
            max-height: 120px;
            overflow-y: auto;
            white-space: pre-wrap;
            user-select: all;
        }

        .clip-box.empty {
            color: var(--text-secondary);
            font-style: italic;
        }

        .button-group {
            display: flex;
            gap: 8px;
        }

        button {
            flex: 1;
            padding: 12px 16px;
            border-radius: 14px;
            border: none;
            font-family: inherit;
            font-size: 13px;
            font-weight: 600;
            cursor: pointer;
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 6px;
            transition: all 0.2s ease;
        }

        button:active {
            transform: scale(0.97);
        }

        .btn-primary {
            background: linear-gradient(135deg, #0381fe, #1d4ed8);
            color: #fff;
            box-shadow: 0 4px 14px rgba(3, 129, 254, 0.3);
        }

        .btn-secondary {
            background: rgba(255, 255, 255, 0.08);
            color: var(--text-primary);
            border: 1px solid var(--card-border);
        }

        textarea {
            width: 100%;
            height: 70px;
            background: rgba(0, 0, 0, 0.25);
            border: 1px solid var(--card-border);
            border-radius: 12px;
            padding: 10px;
            color: var(--text-primary);
            font-family: inherit;
            font-size: 13px;
            resize: none;
            outline: none;
        }

        textarea:focus {
            border-color: var(--galaxy-blue);
        }

        /* Dropzone */
        .dropzone {
            border: 2px dashed rgba(3, 129, 254, 0.4);
            border-radius: 16px;
            padding: 24px 16px;
            text-align: center;
            cursor: pointer;
            transition: all 0.2s ease;
            background: rgba(3, 129, 254, 0.04);
            display: flex;
            flex-direction: column;
            align-items: center;
            gap: 8px;
        }

        .dropzone:active, .dropzone.dragover {
            border-color: var(--galaxy-blue);
            background: rgba(3, 129, 254, 0.12);
        }

        .drop-icon {
            font-size: 32px;
        }

        .drop-text {
            font-size: 14px;
            font-weight: 600;
        }

        .drop-subtext {
            font-size: 11px;
            color: var(--text-secondary);
        }

        /* Progress Bar */
        .progress-bar-container {
            width: 100%;
            height: 8px;
            background: rgba(255, 255, 255, 0.08);
            border-radius: 4px;
            overflow: hidden;
            display: none;
        }

        .progress-bar {
            height: 100%;
            width: 0%;
            background: linear-gradient(90deg, #0381fe, #10b981);
            transition: width 0.1s linear;
        }

        /* File List */
        .file-list {
            display: flex;
            flex-direction: column;
            gap: 8px;
        }

        .file-item {
            display: flex;
            align-items: center;
            justify-content: space-between;
            background: rgba(255, 255, 255, 0.04);
            border: 1px solid var(--card-border);
            padding: 10px 12px;
            border-radius: 12px;
        }

        .file-info {
            display: flex;
            align-items: center;
            gap: 10px;
            overflow: hidden;
        }

        .file-name {
            font-size: 13px;
            font-weight: 600;
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
            max-width: 200px;
        }

        .file-size {
            font-size: 11px;
            color: var(--text-secondary);
        }

        /* Toast */
        #toast {
            position: fixed;
            bottom: 24px;
            left: 50%;
            transform: translateX(-50%) translateY(100px);
            background: rgba(15, 23, 42, 0.95);
            border: 1px solid rgba(255, 255, 255, 0.15);
            color: #fff;
            padding: 10px 18px;
            border-radius: 30px;
            font-size: 13px;
            font-weight: 600;
            box-shadow: 0 10px 25px rgba(0,0,0,0.5);
            display: flex;
            align-items: center;
            gap: 8px;
            transition: transform 0.3s cubic-bezier(0.175, 0.885, 0.32, 1.275);
            z-index: 9999;
            pointer-events: none;
        }

        #toast.show {
            transform: translateX(-50%) translateY(0);
        }
    </style>
</head>
<body>
    <div class="container">
        <!-- Header -->
        <header>
            <div class="brand">
                <div class="brand-icon">⚡</div>
                <div>
                    <div class="brand-title">Galaxy Continuity</div>
                    <div class="brand-subtitle" id="peer-name">Connecting to Mac...</div>
                </div>
            </div>
            <div class="status-pill">
                <div class="status-dot" id="status-dot"></div>
                <span id="status-text">Offline</span>
            </div>
        </header>

        <!-- Universal Clipboard -->
        <div class="card">
            <div class="card-header">
                <div class="card-title">
                    <span>📋 Universal Clipboard</span>
                </div>
                <span class="badge" id="clip-time">Live</span>
            </div>
            <div class="clip-box empty" id="mac-clipboard">Waiting for Mac clipboard...</div>
            <div class="button-group">
                <button class="btn-primary" id="btn-copy-mac">
                    <span>📥 Copy to Phone</span>
                </button>
            </div>

            <textarea id="phone-clip-input" placeholder="Type text or paste link here to send to Mac..."></textarea>
            <button class="btn-secondary" id="btn-send-clip">
                <span>🚀 Send to Mac Clipboard</span>
            </button>
        </div>

        <!-- Quick Drop (Files) -->
        <div class="card">
            <div class="card-header">
                <div class="card-title">
                    <span>⚡ Quick Drop</span>
                </div>
                <span class="badge">AirDrop Speed</span>
            </div>

            <div class="dropzone" id="dropzone" onclick="document.getElementById('file-input').click()">
                <div class="drop-icon">📁</div>
                <div class="drop-text">Tap or Drop files here to send to Mac</div>
                <div class="drop-subtext">Photos, videos, PDFs up to any size</div>
                <input type="file" id="file-input" style="display:none" multiple>
            </div>

            <div class="progress-bar-container" id="progress-container">
                <div class="progress-bar" id="progress-bar"></div>
            </div>

            <div class="file-list" id="incoming-files"></div>
        </div>

        <!-- Quick Actions -->
        <div class="card">
            <div class="card-header">
                <div class="card-title">
                    <span>🛠️ Continuity Tools</span>
                </div>
            </div>
            <div class="button-group">
                <button class="btn-secondary" id="btn-ping-mac">
                    <span>🔔 Ping Mac</span>
                </button>
                <button class="btn-secondary" id="btn-test-notif">
                    <span>💬 Test Notify</span>
                </button>
            </div>
        </div>
    </div>

    <div id="toast">✅ Message</div>

    <script>
        let ws = null;
        let macClipboardText = "";
        const host = window.location.hostname || "127.0.0.1";
        const port = window.location.port || "8765";
        const wsUrl = `ws://${host}:${port}/ws`;

        const statusDot = document.getElementById("status-dot");
        const statusText = document.getElementById("status-text");
        const peerName = document.getElementById("peer-name");
        const macClipboardEl = document.getElementById("mac-clipboard");
        const clipTimeEl = document.getElementById("clip-time");
        const toastEl = document.getElementById("toast");

        function showToast(msg) {
            toastEl.textContent = msg;
            toastEl.classList.add("show");
            setTimeout(() => toastEl.classList.remove("show"), 2500);
        }

        // Web Audio Ping chime
        function playChime() {
            try {
                const ctx = new (window.AudioContext || window.webkitAudioContext)();
                const now = ctx.currentTime;
                const osc = ctx.createOscillator();
                const gain = ctx.createGain();
                osc.type = "sine";
                osc.frequency.setValueAtTime(587.33, now); // D5
                osc.frequency.setValueAtTime(880.00, now + 0.12); // A5
                gain.gain.setValueAtTime(0.3, now);
                gain.gain.exponentialRampToValueAtTime(0.001, now + 0.5);
                osc.connect(gain);
                gain.connect(ctx.destination);
                osc.start(now);
                osc.stop(now + 0.5);
            } catch (e) {
                console.log("Audio not allowed yet:", e);
            }
        }

        function connectWS() {
            ws = new WebSocket(wsUrl);

            ws.onopen = () => {
                statusDot.classList.add("connected");
                statusText.textContent = "Connected";
                peerName.textContent = "Mac Connected";
                showToast("⚡ Connected to Mac!");

                // Handshake
                const handshake = {
                    type: "handshake",
                    device: "Samsung Galaxy (Mobile)",
                    platform: "android_web",
                    version: "1.0.0"
                };
                ws.send(JSON.stringify(handshake));

                // Send battery if supported
                if (navigator.getBattery) {
                    navigator.getBattery().then(batt => {
                        const sendBatt = () => {
                            if (ws && ws.readyState === WebSocket.OPEN) {
                                ws.send(JSON.stringify({
                                    type: "battery_update",
                                    level: Math.round(batt.level * 100),
                                    isCharging: batt.charging
                                }));
                            }
                        };
                        sendBatt();
                        batt.addEventListener("levelchange", sendBatt);
                        batt.addEventListener("chargingchange", sendBatt);
                    }).catch(() => {});
                }
            };

            ws.onclose = () => {
                statusDot.classList.remove("connected");
                statusText.textContent = "Offline";
                peerName.textContent = "Reconnecting in 2s...";
                setTimeout(connectWS, 2000);
            };

            ws.onerror = (err) => {
                console.error("WS error:", err);
            };

            ws.onmessage = (event) => {
                try {
                    const msg = JSON.parse(event.data);
                    handleMessage(msg);
                } catch (e) {
                    console.error("Failed to parse message:", e);
                }
            };
        }

        function handleMessage(msg) {
            switch (msg.type) {
                case "handshake_ack":
                    if (msg.device) {
                        peerName.textContent = msg.device;
                    }
                    break;

                case "clipboard":
                    if (msg.content) {
                        macClipboardText = msg.content;
                        macClipboardEl.textContent = msg.content;
                        macClipboardEl.classList.remove("empty");
                        clipTimeEl.textContent = "Just now";
                        showToast("📋 Mac copied new text!");
                    }
                    break;

                case "file_available":
                    addIncomingFile(msg);
                    showToast(`📦 Mac sent: ${msg.filename}`);
                    break;

                case "ping_device":
                    if (navigator.vibrate) {
                        navigator.vibrate([300, 150, 300, 150, 400]);
                    }
                    playChime();
                    showToast("🔔 Mac is pinging your Galaxy!");
                    break;
            }
        }

        // Copy Mac clipboard to Android
        document.getElementById("btn-copy-mac").onclick = () => {
            if (!macClipboardText) {
                showToast("Clipboard is empty");
                return;
            }
            if (navigator.clipboard && navigator.clipboard.writeText) {
                navigator.clipboard.writeText(macClipboardText).then(() => {
                    showToast("✅ Copied to Galaxy Clipboard!");
                }).catch(() => {
                    showToast("Copy permission denied");
                });
            } else {
                showToast("Select text in box to copy");
            }
        };

        // Send text to Mac clipboard
        document.getElementById("btn-send-clip").onclick = () => {
            const input = document.getElementById("phone-clip-input");
            const text = input.value.trim();
            if (!text) {
                showToast("Type something first!");
                return;
            }
            if (ws && ws.readyState === WebSocket.OPEN) {
                ws.send(JSON.stringify({
                    type: "clipboard",
                    content: text,
                    contentType: "text/plain",
                    source: "phone"
                }));
                showToast("🚀 Sent to Mac Clipboard!");
                input.value = "";
            } else {
                showToast("Not connected to Mac");
            }
        };

        // File upload to Mac
        const fileInput = document.getElementById("file-input");
        const progressContainer = document.getElementById("progress-container");
        const progressBar = document.getElementById("progress-bar");

        fileInput.onchange = (e) => {
            const files = e.target.files;
            if (!files || files.length === 0) return;
            uploadFiles(files);
        };

        function uploadFiles(files) {
            for (let i = 0; i < files.length; i++) {
                const file = files[i];
                uploadFile(file);
            }
        }

        function uploadFile(file) {
            progressContainer.style.display = "block";
            progressBar.style.width = "0%";

            const xhr = new XMLHttpRequest();
            xhr.open("POST", "/api/upload", true);
            xhr.setRequestHeader("X-Filename", encodeURIComponent(file.name));
            xhr.setRequestHeader("X-Filesize", file.size);

            xhr.upload.onprogress = (e) => {
                if (e.lengthComputable) {
                    const percent = Math.round((e.loaded / e.total) * 100);
                    progressBar.style.width = percent + "%";
                }
            };

            xhr.onload = () => {
                progressContainer.style.display = "none";
                if (xhr.status === 200) {
                    showToast(`✅ "${file.name}" sent to Mac!`);
                } else {
                    showToast("Upload failed: " + xhr.statusText);
                }
            };

            xhr.onerror = () => {
                progressContainer.style.display = "none";
                showToast("Upload error!");
            };

            xhr.send(file);
        }

        // Add incoming file from Mac
        function addIncomingFile(file) {
            const list = document.getElementById("incoming-files");
            const item = document.createElement("div");
            item.className = "file-item";

            const sizeFormatted = (file.fileSize / (1024 * 1024)).toFixed(1) + " MB";

            item.innerHTML = `
                <div class="file-info">
                    <span style="font-size:22px">📄</span>
                    <div>
                        <div class="file-name">${file.filename}</div>
                        <div class="file-size">${sizeFormatted}</div>
                    </div>
                </div>
                <a href="/api/download/${file.fileId}" download="${file.filename}" style="text-decoration:none">
                    <button class="btn-primary" style="padding: 6px 12px; font-size:12px;">⬇️ Save</button>
                </a>
            `;
            list.insertBefore(item, list.firstChild);
        }

        // Tools
        document.getElementById("btn-ping-mac").onclick = () => {
            if (ws && ws.readyState === WebSocket.OPEN) {
                ws.send(JSON.stringify({
                    type: "ping_device",
                    source: "phone",
                    message: "Samsung Galaxy pinged your Mac!"
                }));
                showToast("🔔 Pinged Mac!");
            }
        };

        document.getElementById("btn-test-notif").onclick = () => {
            if (ws && ws.readyState === WebSocket.OPEN) {
                ws.send(JSON.stringify({
                    type: "phone_notification",
                    app: "WhatsApp",
                    title: "Samsung Galaxy",
                    text: "Test notification forwarded from your Galaxy!",
                    timestamp: Date.now()
                }));
                showToast("💬 Test notification sent to Mac!");
            }
        };

        // Start WS
        connectWS();
    </script>
</body>
</html>
"""
}
