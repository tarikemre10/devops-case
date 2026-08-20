// CRA dev server'ın (:3000) /api isteklerini backend'e iletmesi için.
//
// package.json'daki basit "proxy" alanı yeterli değil: path rewrite yapamaz,
// yani /api/record isteği backend'e /api/record olarak gider ve 404 alır.
// Buradaki yapılandırma nginx'in prod davranışının birebir aynısıdır
// (docker/nginx.conf -> location /api/ { proxy_pass .../; }).
//
// http-proxy-middleware react-scripts'in kendi bağımlılığıdır; yeni paket
// eklenmiyor. CRA bu dosyayı otomatik yükler, ayrıca yapılandırma gerekmez.
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
