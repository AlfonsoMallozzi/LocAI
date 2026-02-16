# DeepHat — "Nameless Terminal"

A hacker-themed AI chat interface with full CRT television effects. The frontend is a **zero-dependency static site** (HTML + CSS + JS) deployed on **Vercel**. It connects to a self-hosted **Ollama** instance running the `deephat` model, exposed via a **Cloudflare Tunnel**.

> [!NOTE]
> This guide targets **Arch Linux**. All commands, paths, and service configurations are Arch-specific.

---

## Architecture

```
┌────────────────┐         ┌───────────────────┐         ┌──────────────────────────────┐
│  User Browser  │ ──────► │  Vercel (static)   │         │  Arch Linux Box (Backend)    │
│                │         │  index.html         │         │                              │
│  fetch() ──────┼────────────────────────────────────►   │  Ollama REST API :11434      │
│  (streaming)   │         │  style.css          │         │  Model: deephat              │
│                │         │  script.js          │         │                              │
└────────────────┘         └───────────────────┘         └──────────────────────────────┘
                                                               ▲
                                                               │  Cloudflare Tunnel
                                                               │  (public HTTPS URL)
```

**The frontend calls Ollama directly from the browser.** There is no backend server, no Node.js, no API proxy — just `fetch()` hitting the Ollama REST API through a Cloudflare Tunnel URL.

---

## Prerequisites

| Requirement         | Minimum                         |
|---------------------|---------------------------------|
| OS                  | Arch Linux (rolling release)    |
| AUR helper          | `yay` or `paru`                 |
| GPU VRAM            | ~4.5 GB (for 7B Q4_K_M model)  |
| GPU drivers         | NVIDIA (`nvidia` / `nvidia-open`) or AMD (`mesa`, ROCm) |
| Network             | Outbound HTTPS for Cloudflare Tunnel |
| Disk (temporary)    | ~30 GB for quantization pipeline (can reclaim after) |
| Tools (quantize)    | `git`, `cmake`, `make`, `g++`, `python3`, `pip` |

Make sure your GPU drivers are properly installed before continuing:
```bash
# NVIDIA — verify driver is loaded
nvidia-smi

# AMD — verify mesa/ROCm
glxinfo | grep "OpenGL renderer"
```

---

## Step 1 — Install Ollama

Install from the AUR:

```bash
# Using yay
yay -S ollama-bin

# Or using paru
paru -S ollama-bin
```

> [!TIP]
> `ollama-bin` is the precompiled binary package. If you prefer building from source, use `ollama` (without `-bin`), but the binary version is recommended for faster installation.

Enable and start the systemd service:

```bash
sudo systemctl enable --now ollama.service
```

Verify it's running:

```bash
systemctl status ollama.service
curl http://localhost:11434/api/tags
```

You should see a JSON response (possibly with an empty model list if this is a fresh install).

---

## Step 2 — Quantize DeepHat-V1-7B (GPU-limited hardware)

The full-precision DeepHat-V1-7B model is **~15 GB** and requires a high-end GPU. Since no pre-quantized GGUF exists, the included `quantize.sh` script automates the full pipeline:

1. Installs Python dependencies (`huggingface_hub`, `transformers`, `torch`, etc.)
2. Clones and builds `llama.cpp` (quantization tool)
3. Downloads `DeepHat/DeepHat-V1-7B` from HuggingFace (~15 GB)
4. Converts to GGUF format (F16 intermediate)
5. Quantizes to **Q4_K_M** (~4.5 GB) — fits on a GTX 1650

```bash
chmod +x quantize.sh
./quantize.sh
```

The script is interactive — it checks prerequisites, shows progress, and offers to clean up intermediate files (~25 GB) when done.

> [!IMPORTANT]
> **Disk space:** You need ~30 GB free temporarily. After quantization, intermediate files can be deleted, leaving only the ~4.5 GB quantized file (`deephat-v1.Q4_K_M.gguf`).

Output: `deephat-v1.Q4_K_M.gguf` in the project directory.

---

## Step 3 — Load the `deephat` Model into Ollama

The included `Modelfile` points to the quantized GGUF file:

```dockerfile
FROM ./deephat-v1.Q4_K_M.gguf

PARAMETER temperature 0.7
PARAMETER top_p 0.9
PARAMETER num_ctx 4096

SYSTEM """
You are DeepHat, created by Kindo.ai. You are a helpful assistant that is an expert
in Cybersecurity and DevOps. You speak in a direct, slightly cryptic manner.
You are helpful but maintain an air of enigma. You never break character.
"""
```

Load it into Ollama:

```bash
ollama create deephat -f Modelfile
```

Verify:

```bash
ollama list
# Should show "deephat" in the output
```

> [!IMPORTANT]
> **VRAM:** The Q4_K_M model needs ~4.5 GB VRAM. Close other GPU-heavy applications before running. Ollama can also split layers between GPU and CPU if VRAM is tight.

If you don't have the deephat model file, you can substitute any Ollama model (e.g. `llama3`, `mistral`, `deepseek-r1:7b`) — just change the model name in the frontend settings (gear icon).

---

## Step 4 — Enable CORS

The browser **blocks** cross-origin requests unless Ollama explicitly allows them. Configure this via the systemd service override:

```bash
sudo systemctl edit ollama.service
```

This opens an editor. Add the following under a `[Service]` section:

```ini
[Service]
Environment="OLLAMA_ORIGINS=*"
```

Save and exit, then restart the service:

```bash
sudo systemctl daemon-reload
sudo systemctl restart ollama.service
```

Verify the environment variable is applied:

```bash
systemctl show ollama.service | grep Environment
# Should show: Environment=OLLAMA_ORIGINS=*
```

> [!CAUTION]
> `OLLAMA_ORIGINS=*` allows **any** origin to query your Ollama instance. This is required for the Vercel-hosted frontend to work but means anyone with your tunnel URL can access the model. See the **Security** section below.

---

## Step 5 — Expose Ollama via Cloudflare Tunnel

The frontend needs a **public HTTPS URL** that routes to your local Ollama on `:11434`.

### Install cloudflared

```bash
yay -S cloudflared-bin
```

### Start a Quick Tunnel (no Cloudflare account required)

```bash
cloudflared tunnel --url http://localhost:11434
```

This prints a random public URL like:

```
https://funny-poodle-abc123.trycloudflare.com
```

**Copy this URL.** The frontend user pastes it into the settings modal (gear icon → `OLLAMA_ENDPOINT`).

### (Optional) Persistent Tunnel with systemd

If you want the tunnel to survive reboots and run in the background:

1. **Authenticate** (requires a free Cloudflare account):
   ```bash
   cloudflared tunnel login
   ```

2. **Create a named tunnel:**
   ```bash
   cloudflared tunnel create deephat
   ```

3. **Configure the tunnel** — create `~/.cloudflared/config.yml`:
   ```yaml
   tunnel: deephat
   credentials-file: /home/<your-user>/.cloudflared/<tunnel-id>.json

   ingress:
     - hostname: deephat.yourdomain.com
       service: http://localhost:11434
     - service: http_status:404
   ```

4. **Add DNS record:**
   ```bash
   cloudflared tunnel route dns deephat deephat.yourdomain.com
   ```

5. **Create a systemd service:**
   ```bash
   sudo cloudflared service install
   sudo systemctl enable --now cloudflared.service
   ```

This gives you a **fixed URL** (`deephat.yourdomain.com`) that doesn't change on restart.

---

## Quick Verification Checklist

Run these commands after setup to verify everything works:

```bash
# 1. Is Ollama running?
curl http://localhost:11434/api/tags
# ✓ Should return JSON with your models listed

# 2. Is the deephat model loaded?
curl -s http://localhost:11434/api/tags | grep deephat
# ✓ Should show "deephat" in the output

# 3. Can you chat with it directly?
curl http://localhost:11434/api/chat -d '{
  "model": "deephat",
  "messages": [{"role":"user","content":"Hello"}],
  "stream": false
}'
# ✓ Should return a JSON response with the AI's reply

# 4. Is the tunnel working?
# Open your Cloudflare Tunnel URL in a browser:
# https://your-tunnel-url.trycloudflare.com/api/tags
# ✓ Should show the same JSON as step 1

# 5. CORS check — open browser DevTools console and run:
# fetch('https://your-tunnel-url.trycloudflare.com/api/tags')
#   .then(r => r.json()).then(console.log)
# ✓ Should print model list without CORS errors
```

---

## What the Frontend Does (Reference)

You don't need to modify any frontend code. This section is for context only.

| File           | Purpose                                                                                           |
|----------------|---------------------------------------------------------------------------------------------------|
| `index.html`   | Chat UI structure + settings modal. Title: **"Nameless Terminal"**                                |
| `style.css`    | Dark terminal theme: emerald-on-black, JetBrains Mono, full CRT effects (scanlines, vignette, flicker, phosphor glow, turn-on animation, heat-wave distortion, random glitch) |
| `script.js`    | Chat logic: streaming fetch to Ollama, conversation memory, settings management                   |
| `vercel.json`  | Vercel config: SPA rewrites + security headers                                                    |

### How the Frontend Talks to Ollama

```
POST {OLLAMA_ENDPOINT}/api/chat
Content-Type: application/json

{
  "model": "deephat",
  "messages": [
    { "role": "user", "content": "Hello" },
    { "role": "assistant", "content": "Hi there" },
    { "role": "user", "content": "Tell me more" }
  ],
  "stream": true
}
```

- **Streaming:** Response is newline-delimited JSON (NDJSON). Each line: `{"message":{"role":"assistant","content":"tok"},"done":false}`
- **Conversation history:** Full `messages` array sent each request (in-memory, lost on refresh)
- **Model name:** Stored in `localStorage` as `ollama_model`, defaults to `"deephat"`
- **Endpoint URL:** Stored in `localStorage` as `ollama_url`
- **Connection status:** Shows `LINKED` / `DISCONNECTED` based on whether a URL is saved (no actual health check)

### Error Handling

If the fetch fails, the chat displays:

```
CONNECTION ERROR: {error message}

Make sure:
1. Ollama is running on your machine
2. Cloudflare Tunnel is active
3. The URL in settings is correct
```

---

## Security Considerations

> [!WARNING]
> The quick tunnel URL changes every time you restart `cloudflared`. **Don't share the URL publicly** — anyone with it can query your model and consume your GPU resources.

- **Quick tunnel URLs** are ephemeral and random. They're fine for development but not for production.
- **Named tunnels** with a fixed domain are recommended for persistent setups. Use Cloudflare Access policies to restrict who can connect.
- **`OLLAMA_ORIGINS=*`** is a wide-open CORS policy. For tighter security, set it to your specific Vercel domain:
  ```bash
  Environment="OLLAMA_ORIGINS=https://your-app.vercel.app"
  ```
- **Firewall:** Ollama listens on `localhost:11434` by default, which is not directly exposed. The Cloudflare Tunnel is the only external access point. No firewall rule changes are needed.

---

## Resource Usage

| Resource          | Impact                                                        |
|-------------------|---------------------------------------------------------------|
| GPU VRAM          | ~4.5 GB locked while model is loaded                           |
| CPU               | Moderate during inference, idle otherwise                      |
| RAM               | ~2-3 GB for Ollama + model overhead                            |
| Network           | Minimal — only active during streaming responses               |
| Disk              | ~4 GB for the model file + ~200 MB for Ollama                  |

> [!TIP]
> Ollama unloads models from VRAM after 5 minutes of inactivity by default. You can change this with `OLLAMA_KEEP_ALIVE` (e.g., `OLLAMA_KEEP_ALIVE=30m` to keep loaded for 30 minutes).

---

## Troubleshooting

| Problem                                 | Solution                                                                                       |
|-----------------------------------------|-----------------------------------------------------------------------------------------------|
| `ollama: command not found`             | Reinstall: `yay -S ollama-bin`                                                                 |
| Ollama service won't start              | Check journal: `journalctl -u ollama.service -e`                                               |
| CORS errors in browser                  | Verify `OLLAMA_ORIGINS=*` is set: `systemctl show ollama.service \| grep Environment`          |
| Model not found                         | Run `ollama list` and check the name matches what the frontend expects                         |
| Tunnel URL doesn't work                 | Restart: `cloudflared tunnel --url http://localhost:11434` and copy the new URL                  |
| Slow responses                          | Check VRAM usage with `nvidia-smi` or `radeontop`. Close other GPU apps.                       |
| `cloudflared: command not found`        | Install: `yay -S cloudflared-bin`                                                              |
| GPU not detected by Ollama              | Verify drivers: `nvidia-smi` (NVIDIA) or check ROCm setup (AMD). Restart Ollama after fixing.  |

---

## Tech Stack

| Component       | Technology                          | Notes                                  |
|-----------------|-------------------------------------|----------------------------------------|
| Frontend        | Vanilla HTML / CSS / JS             | No frameworks, no build step           |
| Hosting         | Vercel                              | Free tier, static files only           |
| Font            | JetBrains Mono (Google Fonts)       | Monospace terminal look                |
| LLM Runtime     | Ollama                              | REST API on `:11434`                   |
| Model           | DeepHat-V1-7B (Q4_K_M via quantize.sh) | ~4.5 GB VRAM                       |
| Quantization    | llama.cpp (Q4_K_M)                 | Automated by `quantize.sh`             |
| Tunnel          | Cloudflare Tunnel (`cloudflared`)   | Exposes localhost to internet          |
| Communication   | Browser `fetch()` + ReadableStream  | Streaming NDJSON                       |

---

## TL;DR

```bash
# 1. Install Ollama
yay -S ollama-bin
sudo systemctl enable --now ollama.service

# 2. Quantize DeepHat-V1-7B (one-time, needs ~30 GB temp)
chmod +x quantize.sh
./quantize.sh

# 3. Load the model
ollama create deephat -f Modelfile

# 4. Enable CORS
sudo systemctl edit ollama.service
# Add: [Service]
#      Environment="OLLAMA_ORIGINS=*"
sudo systemctl daemon-reload
sudo systemctl restart ollama.service

# 5. Expose via tunnel
yay -S cloudflared-bin
cloudflared tunnel --url http://localhost:11434
# Copy the URL → paste into frontend settings

# 6. Verify
curl http://localhost:11434/api/tags
```

---

## Control Panel (Interactive Setup)

Instead of running all the steps manually, use the included **live TUI dashboard**:

```bash
chmod +x deephat-ctl.sh
./deephat-ctl.sh
```

This launches an interactive terminal panel that:
- **Auto-checks** all 7 setup steps every 3 seconds (including GGUF quantization status)
- **Shows green/red status** for each component
- **Lets you fix issues** by pressing `1`–`7`
- **Press `[3]`** to run the quantization pipeline directly from the dashboard
- **Starts and tracks** the Cloudflare Tunnel, displaying the URL live
- Runs entirely in bash — **zero dependencies**
