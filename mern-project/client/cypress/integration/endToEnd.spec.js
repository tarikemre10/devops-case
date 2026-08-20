// Adresler cypress.json'daki baseUrl'den gelir; CI ve docker compose bunu
// CYPRESS_baseUrl env'i ile ezer (compose: http://frontend:8080).
describe("Web site availability", () => {
  after(() => {
    // Temizlik listede yapılmalı: Delete butonu yalnızca /records rotasında var.
    cy.visit("/records");
    cy.contains("Delete").click({ force: true });
  });

  it("API is reachable through the /api proxy", () => {
    // Proxy yolunu (nginx prod / setupProxy dev) doğrudan doğrular.
    cy.request("/api/healthcheck/").then((response) => {
      expect(response.status).to.eq(200);
      expect(response.body).to.have.property("message", "OK");
    });
  });

  it("Sanity listings web site", () => {
    cy.visit("/");
    cy.contains("Create Record").should("exist");
  });

  it("Test Adding Employee listings", () => {
    cy.visit("/create");
    cy.get("#name").type("Employee1");
    cy.get("#position").type("Position1");
    cy.get("#positionIntern").click({ force: true });
    cy.contains("Create person").click({ force: true });

    // Kayıt sonrası uygulama "/" adresine yönlendiriyor, ancak "/" rotası
    // HealthStatus bileşenini render ediyor (bkz. App.js). Kayıt listesi
    // /records altında. Uygulama rotasına dokunulmadı, doğrulama listenin
    // gerçekten bulunduğu adrese taşındı.
    cy.visit("/records");
    cy.contains("Employee1").should("exist");
  });
});
