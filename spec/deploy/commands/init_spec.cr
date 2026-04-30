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

  describe ".parse_confirm_choice" do
    it "Entrée seule = :send (défaut envoi)" do
      Deploy::Commands::Init.parse_confirm_choice("").should eq :send
    end

    it "accepte les variantes oui (O, o, oui, y, yes)" do
      ["O", "o", "Oui", "OUI", "y", "yes", "YES", " o "].each do |s|
        Deploy::Commands::Init.parse_confirm_choice(s).should eq :send
      end
    end

    it "accepte les variantes non (n, non, no)" do
      ["n", "N", "non", "Non", "no", "NO"].each do |s|
        Deploy::Commands::Init.parse_confirm_choice(s).should eq :cancel
      end
    end

    it "accepte les variantes retry (r, re, retry, reprendre)" do
      ["r", "R", "re", "retry", "RETRY", "reprendre"].each do |s|
        Deploy::Commands::Init.parse_confirm_choice(s).should eq :retry
      end
    end

    it "renvoie nil pour une entrée non reconnue" do
      Deploy::Commands::Init.parse_confirm_choice("?").should be_nil
      Deploy::Commands::Init.parse_confirm_choice("foo").should be_nil
      Deploy::Commands::Init.parse_confirm_choice("123").should be_nil
    end
  end
end
