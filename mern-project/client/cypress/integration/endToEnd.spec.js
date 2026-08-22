describe("Web site availability", () => {
  after(() => {
    // Test verisini temizle.
    cy.visit("/records");
    cy.contains("Delete").click({ force: true });
  });

  it("API is reachable through the /api proxy", () => {
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

    cy.visit("/records");
    cy.contains("Employee1").should("exist");
  });
});
