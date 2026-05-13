# heyo_xmpp_client

Lightweight XMPP client for Ruby with:
- `Xmpp::Client`
- Plugin system (`Xmpp::Plugin`)
- Built-in plugins:
  - `Xmpp::Plugins::ModInbox`
  - `Xmpp::Plugins::TokenReconnection`
  - `Xmpp::Plugins::MucLight` — MongooseIM [MUC Light](https://mongooseim-global-distrib.readthedocs.io/en/latest/open-extensions/muc_light/) group chat
  - `Xmpp::Plugins::Pubsub` — MongooseIM [mod_pubsub](https://esl.github.io/MongooseDocs/latest/modules/mod_pubsub/) (XEP-0060)

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

## MUC Light (MongooseIM)

```ruby
muc = client.use(Xmpp::Plugins::MucLight)

muc.on_message            { |evt| puts "#{evt[:from]}: #{evt[:body]}" }
muc.on_affiliation_change { |evt| puts "affiliations: #{evt[:users]}" }
muc.on_room_destroyed     { |evt| puts "destroyed: #{evt[:room_jid]}" }

room = muc.create_room(name: "Devs", occupants: ["alice@example.com"])
muc.send_groupchat_message(room[:room_jid], "Hello, room!")
muc.invite(room[:room_jid], "bob@example.com")
muc.set_configuration(room[:room_jid], subject: "Daily standup")
muc.rooms                       # => list of rooms the user is in
muc.kick(room[:room_jid], "alice@example.com")
muc.leave(room[:room_jid])
```

The service host defaults to `muclight.<your-domain>`. Override with
`client.use(Xmpp::Plugins::MucLight, service_host: "groups.example.com")`.

## PubSub (MongooseIM)

```ruby
ps = client.use(Xmpp::Plugins::Pubsub)

ps.on_item_published   { |evt| puts "#{evt[:node]} #{evt[:item_id]}: #{evt[:payload_xml]}" }
ps.on_item_retracted   { |evt| puts "retracted #{evt[:item_id]} from #{evt[:node]}" }
ps.on_node_deleted     { |evt| puts "deleted node #{evt[:node]}" }
ps.on_subscription_change { |evt| puts "sub #{evt[:node]} -> #{evt[:subscription]}" }

ps.create_node("blog")
ps.subscribe("blog")
ps.publish("blog", "<entry xmlns='http://www.w3.org/2005/Atom'><title>Hi</title></entry>")
ps.items("blog")               # => [{ id:, publisher:, payload_xml: }, ...]
ps.subscriptions               # requester-scoped
ps.affiliations(node: "blog")  # node-scoped (owner)
ps.set_affiliations("blog", changes: [{ jid: "bob@example.com", affiliation: "publisher" }])
ps.unsubscribe("blog")
ps.delete_node("blog")
```

The service host defaults to `pubsub.<your-domain>`. Override with
`client.use(Xmpp::Plugins::Pubsub, service_host: "ps.example.com")`.

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
