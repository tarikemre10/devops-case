// Lokal geliştirmede nginx ile aynı /api rewrite'ını kullan.
const { createProxyMiddleware } = require("http-proxy-middleware");

module.exports = function (app) {
  app.use(
    "/api",
    createProxyMiddleware({
      target: process.env.API_PROXY_TARGET || "http://localhost:5050",
      changeOrigin: true,
      pathRewrite: { "^/api": "" },
    })
  );
};
