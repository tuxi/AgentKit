import { defineConfig } from "vite";
import { fileURLToPath, URL } from "node:url";

export default defineConfig({
  base: "./",
  build: {
    outDir: fileURLToPath(
      new URL("../../Sources/AgentKit/Resources/ConversationWeb", import.meta.url),
    ),
    emptyOutDir: true,
    sourcemap: false,
    assetsDir: "assets",
    rollupOptions: {
      output: {
        entryFileNames: "assets/workbench.js",
        chunkFileNames: "assets/chunk-[hash].js",
        assetFileNames: "assets/workbench.[ext]",
      },
    },
  },
});
