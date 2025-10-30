#!/usr/bin/env bash
# © David Leadbeater <https://©.st/dgl>; NO WARRANTY
# SPDX-License-Identifier: 0BSD
#
# "Pure"(*) bash IRCd -- https://dgl.cx/bash-ircd
# *: Uses various loadable bash builtins
#
# Credit to https://github.com/bahamas10/bash-web-server for ideas,
# see also https://youtu.be/L967hYylZuc

set -euo pipefail
shopt -s extglob nocasematch

PORT=6667
ADDRESS=127.0.0.1
SERVER=irc.example.com

# Ensure we stay pure:
readonly PATH=""

need_loadables() {
  echo "To use this script needs a version of bash with loadables." >&2
  echo "On some systems you may need to install a package like bash-builtins." >&2
  exit 127
}

# The loadable bash builtins needed:
enable accept || need_loadables
enable mkfifo || need_loadables
enable rm || need_loadables

nick=
user=
state=new
declare -a channels=()

lower() {
  # Usage: lower "string"
  printf '%s\n' "${1,,}"
}

process-client() {
  local line command

  # stdin is stdout too, because it's a socket
  exec >&0

  while read -t120 -r line; do
    line="${line//$'\r'}"
    # Clients can't send prefixes
    line="${line#:+([^ ]) }"
    commands-$state "${line%% *}" "${line##+([^ ])*( )}"
  done
}

WPID=

reply-numeric() {
  local numeric=$1
  local msg=$2
  echo ":${SERVER} $numeric ${nick:-*} $msg"$'\r'
}

maybe-connect() {
  [[ -z $user ]] && return
  [[ -z $nick ]] && return
  state=on
  reply-numeric "001" ":Welcome to IRC, ${nick}!"
  reply-numeric "002" ":Your host is ${SERVER} on bash ircd v0.0.1, bash ${BASH_VERSION}"
  reply-numeric "004" "${SERVER} 0.0.1 i o o"
  watcher&
  WPID=$!
  trap 'send-quit; kill $WPID; rm -f "user-$nick"' EXIT
}

watcher() {
  local last=$SECONDS
  while true; do
    exec <"user-$nick"
    while read -t90 -r line; do
      echo "$line"
    done
    if [ $[SECONDS-last] -ge 90 ]; then
      echo "PING :${SERVER}"
      last=$SECONDS
    fi
  done
}

# Commands for unregistered connections
commands-new() {
  local command="$1"
  local args="$2"
  case $command in
    QUIT)
      send-quit "${args#@(:)}"
      channels=()
      exit 0
    ;;
    NICK)
      [[ -n $nick ]] && return
      arg="${args#@(:)}"
      # Stricter than RFC, but avoids issues with shell metacharacters.
      local arg_validated="${args/@([^a-z0-9_])}"
      if [[ $arg != $arg_validated ]]; then
        reply-numeric "432" "$arg :Erroneous Nickname"
        return
      fi
      nick=$(lower "$arg")
      if [[ -e "user-$nick" ]]; then
        reply-numeric "433" "$arg :Nickname already in use"
        nick=
      else
        mkfifo "user-$nick"
        trap 'rm -f "user-$nick"' EXIT
      fi
      maybe-connect
    ;;
    USER)
      user=1
      maybe-connect
    ;;
    *) reply-numeric 421 "${command} :Unknown command";;
  esac
}

# Commands for registered connections, $nick is valid.
commands-on() {
  local command="$1"
  local args="$2"
  case $command in
    PONG) ;;
    PING)
      echo ":${SERVER} PONG ${SERVER} $args"
    ;;
    QUIT) exit 1;;
    NICK) ;; # cannot change nick once connected
    JOIN)
        local chan="${args%% *}"
        chan="$(lower "${chan#@(:)}")"
        # TODO: IFS=, and do each channel if join is a list.
	local chan_validated="${chan/@([^#a-z0-9_-])}"
        if [[ $chan != $chan_validated ]]; then
          reply-numeric 479 "$chan :Illegal channel name"
          return
        fi
        # already in it?
        local n=0
        for channel in ${channels[@]}; do
          [[ $channel = $chan ]] && return
          n=$[n+1]
        done
        if [[ $n > 10 ]]; then
          return
        fi
	channels[${#channels[@]}]=$chan
	echo "$nick" >> "channel-$chan"
        for n in $(<channel-$chan); do
          echo ":$nick!user@host JOIN $chan" >> "user-$n"
        done
    ;;
    PRIVMSG)
      if [[ ${args/ } = $args ]]; then
        reply-numeric 412 ":No text to send"
        return
      fi
      local to="$(lower "${args%% *}")"
      local msg="${args##+([^ ]) *(:)}"
      if [[ ${to:0:1} = "#" ]]; then
	local to_validated="${to/@([^#a-z0-9_-])}"
	if [[ $to != $to_validated ]] || [ ! -f "channel-$to" ]; then
	  reply-numeric 401 ":No such nick/channel"
	  return
        fi
        for n in $(<channel-$to); do
          if [[ $n != $nick ]]; then
	    echo ":$nick!user@host PRIVMSG $to :$msg" >> "user-$n"
          fi
        done
      else
	local to_validated="${to/@([^a-z0-9_-])}"
	if [[ $to != $to_validated ]] || [ ! -p "user-$to" ]; then
	  reply-numeric 401 ":No such nick/channel"
	  return
	fi
	echo ":${nick}!user@host PRIVMSG $to :${msg}" >> user-$to
      fi
    ;;
    *) reply-numeric 421 "${command} :Unknown command";;
  esac
}

send-quit() {
  local msg="${1:-}"
  local -A tosend
  for channel in ${channels[@]}; do
    for n in $(<channel-$channel); do
      tosend["$n"]=1
    done
  done
  for n in ${!tosend[@]}; do
    echo ":$nick!user@host QUIT :$msg"
  done
}

while true; do
  accept -b "$ADDRESS" -v fd -r ip "$PORT"
  process-client <&"$fd" &
  # close in parent
  exec {fd}>&-
done
