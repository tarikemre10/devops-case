// Tüm API çağrılarının tek giriş noktası.
//
// Göreli yol kullanılır: istek her zaman sayfanın kendi origin'ine gider ve
// oradan backend'e proxy'lenir —
//   prod  : nginx  (location /api/ -> backend Service)
//   dev   : src/setupProxy.js (aynı rewrite'ı CRA dev server'da taklit eder)
//
// REACT_APP_API_URL bilinçli olarak kullanılmıyor: Create React App env
// değişkenlerini build sırasında gömer, bu da aynı Docker image'ının farklı
// ortamlarda kullanılamaması demektir. Göreli yol ile tek image her yerde
// çalışır ve CORS'a hiç ihtiyaç kalmaz.
export const API_URL = "/api";
