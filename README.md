# A bash IRCd 🐣 💬

[This](./ircd.sh) is an IRC server written in bash. It is nearly "pure" bash,
because it does not use any external commands. But it does cheat slightly by
using some loadable builtins.

<img src="screen.png">

Credit to [YSAP](https://www.youtube.com/@yousuckatprogramming) for
[bash-web-server](https://github.com/bahamas10/bash-web-server). Inspiration
from [example.fi's IRCd service](https://example.fi/blog/ircd.html), which
unfortunately hasn't published the code behind it.

## Running

```
./ircd.sh
```

Connect to localhost:6667 with an IRC client. If using Irssi you need to use
`/connect -nocap localhost`.

## Architecture 🏗️

The `accept` loadable bash builtin makes it possible to listen on a socket. See
the very end of the script for that.

Then "process-client" runs as another process with stdin/stdout set to the
client (this means `echo` to send to the client just works). Nicknames are kept
by a `user-${name}` FIFO on the filesystem. Once the client has registered another
process ("watcher") that reads from that FIFO and writes to the client is
started, this means other clients can directly write to the FIFO, which in turn
directly writes to the user's connection.

Watcher also is responsible for sending PINGs, which means if process-client
hits a timeout, it exits, as the client should have sent a ping back already.

Channels are plain text files with a nickname per line and are simply expanded
by process-client running as the sending user when needing to send to them.

Unlike the original IRC server software, which used non-blocking I/O so it
could efficiently support many clients in a single process, this architecture
results in at least 2 processes per connection, so is hardly scalable. However,
because it uses FIFOs parts of it can be upgraded without disconnecting other
clients. If you ^C ircd.sh (and keep your shell/session running) clients will
stay connected, but new clients cannot connect, until you run `ircd.sh` again.

As each user is a FIFO, you can use this to send messages to users from outside
the IRCd on the server machine:

```bash
msg-user() {
  local to="$1"
  local msg="$2"
  echo ':'"${USER}"'!user@host PRIVMSG '"${to} :${msg}" >> "user-${to}"
}
```

## Bugs 🐛

This is full of them. Not recommended for production use, in particular the use
of FIFOs means there are various cases where a misbehaving client can block
sending to them, which could slowly block all messages being sent to a channel.
I don't think that is fixable in pure Bash.

## Security 🔐 🚨

I suspect this has some hilarious security holes. You could put stunnel in
front of it to make it do TLS, but that's like putting lipstick on a pig.

## Contributing 🧑‍💻

PRs welcome. This so far has been written without any AI, please disclose any
usage. I or others might be in ##bash-ircd on Libera.
