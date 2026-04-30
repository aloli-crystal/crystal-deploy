require "../../spec_helper"

describe Deploy::Commands::Init do
  describe ".secret_key?" do
    it "détecte les patterns classiques de secret" do
      Deploy::Commands::Init.secret_key?("APP_SECRET").should be_true
      Deploy::Commands::Init.secret_key?("SECRET_KEY").should be_true
      Deploy::Commands::Init.secret_key?("API_TOKEN").should be_true
      Deploy::Commands::Init.secret_key?("DATABASE_PASSWORD").should be_true
      Deploy::Commands::Init.secret_key?("STRIPE_KEY").should be_true
    end

    it "détecte SMTP_PASS (qui ne contient pas 'password' au sens strict)" do
      Deploy::Commands::Init.secret_key?("SMTP_PASS").should be_true
      Deploy::Commands::Init.secret_key?("smtp_pass").should be_true
    end

    it "ignore les noms qui ne sont pas des secrets" do
      Deploy::Commands::Init.secret_key?("APP_DOMAIN").should be_false
      Deploy::Commands::Init.secret_key?("MAIL_FROM").should be_false
      Deploy::Commands::Init.secret_key?("PORT").should be_false
      Deploy::Commands::Init.secret_key?("HOST").should be_false
    end

    it "exclut explicitement la clé publique Stripe" do
      Deploy::Commands::Init.secret_key?("STRIPE_PUBLISHABLE_KEY").should be_false
    end
  end
end
