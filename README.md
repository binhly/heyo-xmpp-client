# heyo_xmpp_client

Lightweight XMPP client for Ruby with:
- `Xmpp::Client`
- Plugin system (`Xmpp::Plugin`)
- Built-in plugins:
  - `Xmpp::Plugins::ModInbox`
  - `Xmpp::Plugins::TokenReconnection`

## Installation

### From a path in another app

```ruby
# Gemfile
gem "heyo_xmpp_client", path: "../heyo_xmpp_client"
```

### From RubyGems (after publishing)

```ruby
# Gemfile
gem "heyo_xmpp_client"
```

Then run:

```bash
bundle install
```

## Usage

```ruby
require "heyo_xmpp_client"

client = Xmpp::Client.new(
  jid: "user@example.com",
  password: "secret",
  host: "example.com",
  use_tls: :starttls
)

client.use(Xmpp::Plugins::TokenReconnection, auto_request: true)
client.use(Xmpp::Plugins::ModInbox)

client.connect
client.send_presence(status: "Online")
client.disconnect
```

## Rails integration pattern

Use a background job to connect and refresh tokens after login, then use a service from controllers for short-lived calls.

```ruby
class XmppTokenRefreshJob < ApplicationJob
  queue_as :default

  def perform(user_id)
    user = User.find(user_id)
    client = Xmpp::Client.new(
      jid: user.xmpp_jid,
      password: user.xmpp_password,
      host: ENV.fetch("XMPP_HOST")
    )

    token_plugin = client.use(
      Xmpp::Plugins::TokenReconnection,
      auto_request: false
    )

    token_plugin.update_tokens(
      access_token: user.xmpp_access_token,
      refresh_token: user.xmpp_refresh_token
    )

    client.connect
    tokens = token_plugin.request_tokens
    user.update!(
      xmpp_access_token: tokens[:access_token],
      xmpp_refresh_token: tokens[:refresh_token]
    )
  ensure
    client&.disconnect
  end
end
```

## Build the gem

```bash
gem build heyo_xmpp_client.gemspec
```
