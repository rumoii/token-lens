import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

/**
 * 开发期：把 `/api` 转发给本机正在运行的 `lens serve`，并把数据目录里的
 * API 令牌注入 index.html。
 *
 * 生产构建不走这里：`lens serve` 自己从 dist 提供页面并注入同一个 meta。
 */
function lensDevBridge() {
  const apiTarget = process.env.LENS_API_URL || "http://127.0.0.1:3456";
  const dataDir = process.env.TOKEN_LENS_DATA_DIR || path.join(os.homedir(), ".token-lens");
  const tokenPath = path.join(dataDir, "api-token");

  const readToken = () => {
    try {
      return fs.readFileSync(tokenPath, "utf8").trim();
    } catch {
      return null;
    }
  };

  return {
    name: "lens-dev-bridge",
    apply: "serve",
    transformIndexHtml(html) {
      const token = readToken();
      if (!token) return html;
      const meta = `<meta name="lens-api-token" content="${token}" />`;
      return html.replace("</head>", `    ${meta}\n  </head>`);
    },
    config() {
      return {
        server: {
          proxy: {
            "/api": {
              target: apiTarget,
              changeOrigin: true,
              // 写入接口要求同源：把 Origin 改写成目标源，避免开发端口被 403
              configure(proxy) {
                proxy.on("proxyReq", (proxyReq) => {
                  proxyReq.setHeader("origin", apiTarget);
                });
              }
            }
          }
        }
      };
    }
  };
}

export default defineConfig({
  plugins: [react(), lensDevBridge()],
  server: {
    port: 5173,
    strictPort: false
  }
});
