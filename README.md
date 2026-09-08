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

### Client options

`Xmpp::Client.new` accepts these optional keyword arguments:

| Option | Default | Description |
| --- | --- | --- |
| `host` | the JID domain | Server host to connect to |
| `port` | `5222` | Server port |
| `use_tls` | `:starttls` | `:starttls`, `:always`, or `nil` |
| `resource` | `"ruby"` | Resource used when binding |
| `reconnect` | `true` | Automatically reconnect after unexpected drops |
| `reconnect_max_attempts` | `nil` | Maximum reconnects before raising (`nil` = unlimited) |
| `reconnect_base_interval` | `1` | Initial backoff in seconds |
| `reconnect_max_interval` | `30` | Backoff cap in seconds |
| `ping_interval` | `60` | Seconds between XMPP pings (`0` disables) |
| `connect_timeout` | `10` | Seconds allowed for TCP/TLS connect |
| `read_timeout` | `30` | Seconds allowed while waiting for a stanza/IQ response |

If no response arrives within `read_timeout`, a `Xmpp::Client::TimeoutError` is
raised instead of blocking forever. The JID may include a resource
(`"user@domain/resource"`); it is stripped for the connection and binding.

### Sending and receiving messages

```ruby
client = Xmpp::Client.new(jid: "user@example.com", password: "secret")
client.connect

client.send_message(to: "bob@example.com", body: "Hello!")
client.send_presence(status: "Online")

# Receiving: listen blocks, yielding each stanza as raw XML. Run it on a
# dedicated thread; it raises Xmpp::Error if the connection dies.
listener = Thread.new do
  client.listen do |xml|
    puts xml # e.g. <message to='...' type='chat'><body>Hi</body></message>
  end
end

client.disconnect
```

`send_message` is fire-and-forget: it returns once the stanza is written to
the (TLS-protected) stream. XMPP does not give a delivery receipt here —
check for a returned `error`-type stanza via `listen` if you need bounce
detection.

## Error handling

All errors raised by the gem derive from `Xmpp::Error`, so a single
`rescue Xmpp::Error` covers the client's failure modes:

| Class | Raised when |
| --- | --- |
| `Xmpp::Error` | Base class; also used for transport failures (connection refused, write on a dead socket) |
| `Xmpp::AuthenticationError` | SASL failure (PLAIN rejected, token auth rejected with no fallback left). Carries the server's `<failure/>` element in `#failure_element` |
| `Xmpp::ProtocolError` | The server violated the protocol: STARTTLS `<failure/>`, STARTTLS not offered when required, malformed bind result |
| `Xmpp::Client::TimeoutError` | A bounded wait (connect, IQ response, stanza) elapsed |

```ruby
begin
  client.connect
rescue Xmpp::AuthenticationError => e
  reason = e.failure_element&.children&.first&.name # e.g. "not-authorized"
  warn "auth failed: #{reason || e.message}"
rescue Xmpp::Client::TimeoutError
  warn "server did not complete the handshake in time"
rescue Xmpp::Error => e
  warn "xmpp failure: #{e.message}"
end
```

Notes:

- `send_raw` (and therefore `send_message`, `send_presence`, `request_iq`)
  raises `Xmpp::Error` when the client is not connected.
- With `reconnect: true`, a dropped connection heals transparently on the
  read *and* write paths; a request in flight at drop time still fails with
  `Xmpp::Client::TimeoutError` because there is no XEP-0198 replay.

## Scope and limitations

Read this section before choosing this gem for a non-MongooseIM server.

- **Auth mechanisms**: SASL `PLAIN` and the MongooseIM token extension
  (`erlang-solutions.com:xmpp:token-auth:0`, SASL `X-OAUTH`). No SCRAM; PLAIN
  is only attempted over a TLS-protected stream — with `use_tls: :starttls`
  (the default) the client refuses to authenticate when the server does not
  offer STARTTLS.
- **No stream resumption**: there is no XEP-0198 support. Reconnection after
  a drop is a full re-handshake (new stream, TLS, SASL, bind); an in-flight
  request is lost and its caller sees `Xmpp::Client::TimeoutError`.
- **JID handling**: JIDs are split on `@` and `/` (`user@domain/resource`);
  there is no stringprep (RFC 7622) validation. Non-ASCII or edge-case
  localparts are untested.
- **Target server**: MongooseIM. The covered feature set follows RFC 6120/6121
  and should work with generic servers, but CI only tests against
  MongooseIM.

## Writing your own plugin

Plugins extend `Xmpp::Plugin` and receive the client in the constructor.
Override the hooks you need; everything is optional:

```ruby
class MyLogger < Xmpp::Plugin
  def on_connect
    # session bound and established; safe to send stanzas
  end

  def on_disconnect(error: nil)
    # error is the exception that killed the connection, if any
  end

  def on_stream_features(features)
    # raw <stream:features> REXML element, delivered on every (re)connect
  end

  def on_stanza(stanza)
    # every incoming stanza (REXML element)
  end

  def before_send(xml)
    # inspect or rewrite outgoing XML; return the new string (or nil to
    # leave the original untouched)
  end
end

client.use(MyLogger)
```

Registration order matters: `before_send` hooks run in the order plugins
were registered, and `on_stanza` fan-out likewise. A plugin raising inside a
hook does not kill the connection — `PluginManager` logs the failure and
continues with the remaining plugins, so wrap risky hook bodies in your own
error handling if a missed event is unacceptable.

The SASL hook `sasl_authenticate(client, features)` is special: the first
plugin returning non-`nil` owns authentication. Return `true` after a
successful exchange, `false` to trigger the stream-restart PLAIN fallback
(see token auth below), or `nil` to decline.

## Token auth (MongooseIM X-OAUTH)

`Xmpp::Plugins::TokenReconnection` authenticates with the MongooseIM token
extension instead of the account password. Pass tokens with
`update_tokens(access_token:, refresh_token:)`; with the default
`auto_request: true` the plugin also fetches fresh tokens from the server
after connecting (`request_tokens`).

On connect the plugin sends SASL `X-OAUTH`. If the server rejects the token:

1. The client tears down the stream and reconnects from scratch — always
   through the same STARTTLS gate as a normal connect, so the password never
   goes out over plaintext.
2. It retries with SASL `PLAIN` (password) on the new stream. The fallback
   happens once per `connect`: if X-OAUTH is rejected a second time, the
   client raises `Xmpp::AuthenticationError` ("Token auth rejected and
   password fallback disabled") instead of looping.

`TokenReconnection` clears the rejected token after a failure, so on the
retry it declines and lets the client fall through to PLAIN. If you need
different behavior, write your own plugin (see above) returning `false` from
`sasl_authenticate`.

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
