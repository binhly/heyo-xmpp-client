require_relative "lib/heyo_xmpp_client/version"

Gem::Specification.new do |spec|
  spec.name = "heyo_xmpp_client"
  spec.version = HeyoXmppClient::VERSION
  spec.authors = ["Binh Ly"]
  spec.email = ["binh@hey.com"]

  spec.summary = "Simple XMPP client with plugin support."
  spec.description = "A lightweight XMPP client with reconnection support and pluggable features such as mod_inbox, token-based auth, MUC Light, and PubSub."
  spec.homepage = "https://github.com/binhly/heyo_xmpp_client"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.files = Dir.chdir(__dir__) do
    Dir["lib/**/*.rb"] + Dir["README.md", "LICENSE.txt"]
  end

  spec.require_paths = ["lib"]

  spec.add_dependency "base64"
  spec.add_dependency "rexml", "~> 3.2"
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
