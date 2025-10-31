#!/usr/bin/env bash
# © David Leadbeater <https://©.st/dgl>; NO WARRANTY
# SPDX-License-Identifier: 0BSD
#
# "Pure"(*) bash IRCd -- https://dgl.cx/bash-ircd
# *: Uses various loadable bash builtins
#
# Credit to https://github.com/bahamas10/bash-web-server for ideas,
# see also https://youtu.be/L967hYylZuc

set -euoo pipefail noclobber
shopt -s extglob nocasematch

PORT="${PORT:-6667}"
ADDRESS="${ADDRESS:-127.0.0.1}"
SERVER="${SERVER:-irc.example.com}"

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

  while IFS=$'\n' read -t120 -r line; do
    line="${line//$'\r'}"
    # Enforce IRC line length limit
    line="${line:0:512}"
    # Clients can't send prefixes, strip them
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
  reply-numeric "002" ":Your host is ${SERVER} on bash-ircd v0.0.1, bash ${BASH_VERSION}"
  reply-numeric "004" "${SERVER} 0.0.1 i o o"
  watcher&
  WPID=$!
  trap 'send-quit; kill $WPID; rm -f "user-$nick"' EXIT
}

watcher() {
  local last=$SECONDS
  while true; do
    exec <"user-$nick"
    while IFS=$'\n' read -t90 -r line; do
      echo "$line"
    done
    if [ $((SECONDS-last)) -ge 90 ]; then
      echo "PING :${SERVER}"$'\r'
      last=$SECONDS
    fi
  done
}

# Commands for unregistered connections
commands-new() {
  local command="$1"
  local args="$2"
  case $command in
    QUIT) exit 0;;
    NICK)
      [[ -n $nick ]] && return
      arg="${args#@(:)}"
      # Stricter than RFC, but avoids issues with shell metacharacters.
      local arg_validated="${args/@([^a-z0-9_])}"
      if [[ $arg != "$arg_validated" ]]; then
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
      echo ":${SERVER} PONG ${SERVER} $args"$'\r'
    ;;
    QUIT)
      send-quit "${args#:}"
      channels=()
      exit 0
    ;;
    NICK) ;; # cannot change nick once connected
    JOIN)
      local arg="${args%% *}"
      arg="$(lower "${arg#:}")"
      while [[ -n "$arg" ]]; do
        local chan="${arg%%,*}"
        arg="${arg##+([^,])?(,)}"
        local chan_valid="${chan/@([^#a-z0-9_-])}"
        if [[ ${chan_valid:0:1} != "#" || $chan != "$chan_valid" ]]; then
          reply-numeric 479 "$chan :Illegal channel name"
          return
        fi
        # already in it?
        local n=0
        for channel in "${channels[@]}"; do
          [[ $channel = "$chan" ]] && return
          n=$((n+1))
        done
        if [[ $n -gt 10 ]]; then
          # TODO: Too many channels
          return
        fi
        channels[${#channels[@]}]=$chan
        if [ ! -f "meta-$chan" ]; then
          # Can lose race here, fine.
          if echo "$EPOCHSECONDS" > "meta-$chan"; then
            # Empty topic and set by
            echo "" >> "meta-$chan"
            echo "" >> "meta-$chan"
            echo "0" >> "meta-$chan"
          fi
        fi
        echo "$nick" >> "channel-$chan"
        local users=""
        for n in $(<"channel-$chan"); do
          send-to-user "$n" "JOIN $chan"
          users="${users} $n"
        done
        reply-numeric 353 "= $chan :${users# }"
        reply-numeric 366 "$chan :End of /NAMES list"
        local ts topic setby when
        exec 3<"meta-$chan"
        read ts <&3 && reply-numeric 329 "$chan $ts"
        if IFS= read topic <&3 && [[ -n "$topic" ]]; then
          reply-numeric 332 "$chan :$topic"
          read setby <&3 || :
          read when <&3 || :
          reply-numeric 333 "$chan $setby $when"
        fi
        exec 3>&-
      done
    ;;
    PRIVMSG|NOTICE)
      if [[ ${args/ } = "$args" ]]; then
        reply-numeric 412 ":No text to send"
        return
      fi
      local to msg
      to="$(lower "${args%% *}")"
      msg="${args##+([^ ]) *(:)}"
      if [[ ${to:0:1} = "#" ]]; then
        local to_validated="${to/@([^#a-z0-9_-])}"
        if [[ $to != "$to_validated" ]] || [ ! -f "channel-$to" ]; then
          reply-numeric 401 ":No such nick/channel"
          return
        fi
        for n in $(<"channel-$to"); do
          if [[ $n != "$nick" ]]; then
            send-to-user "$n" "$command $to :$msg"
          fi
        done
      else
        local to_validated="${to/@([^a-z0-9_-])}"
        if [[ $to != "$to_validated" ]] || [ ! -p "user-$to" ]; then
          reply-numeric 401 ":No such nick/channel"
          return
        fi
        send-to-user "$to" "$command $to :${msg}"
      fi
    ;;
    TOPIC)
      local chan topic
      chan="$(lower "${args%% *}")"
      topic="${args##+([^ ]) *(:)}"
      if [[ ${chan:0:1} != "#" ]]; then
        reply-numeric 403 ":No such channel"
        return
      fi
      local chan_valid="${chan/@([^#a-z0-9_-])}"
      local file="meta-$chan"
      if [[ $chan != "$chan_valid" ]] || [ ! -f "$file" ]; then
        reply-numeric 403 ":No such channel"
        return
      fi
      local ts
      exec 3<"$file"
      read ts <&3
      exec 3>&-
      # noclobber needed, acts as lockfile
      local write=1
      echo "$ts" > ".$file" || write=0
      if [[ $write = 1 ]]; then
        echo "$topic" >> ".$file"
        echo "$nick" >> ".$file"
        echo "$EPOCHSECONDS" >> ".$file"
        echo "$(<".$file")" >| "$file"
        rm ".$file"
        for n in $(<"channel-$chan"); do
          send-to-user "$n" "TOPIC $chan :$topic"
        done
      fi
    ;;
    *) reply-numeric 421 "${command} :Unknown command";;
  esac
}

send-to-user() {
  local user="$1"
  local line=":$nick!user@host $2"$'\r'
  if [[ $user = "$nick" ]]; then
    echo "$line"
  elif [ -p "user-$user" ]; then
    echo "$line" >> "user-$user"
  fi
}

send-quit() {
  local msg="${1:-}"
  local -A tosend
  for channel in "${channels[@]}"; do
    # noclobber needed, acts as lockfile
    local write=1
    local file="channel-$channel"
    echo -n > ".$file" || write=0
    for n in $(<"$file"); do
      # filter out other users who have gone away
      [[ -p "user-$n" ]] || continue
      tosend["$n"]=1
      # filter out this user
      [[ $n = "$nick" ]] && continue
      [[ $write = 1 ]] && echo "$n" >> ".$file"
    done
    if [[ $write = 1 ]]; then
      echo "$(<".$file")" >| "$file"
      rm ".$file"
    fi
  done
  for n in "${!tosend[@]}"; do
    send-to-user "$n" "QUIT :$msg"
  done
}

while true; do
  accept -b "$ADDRESS" -v fd -r ip "$PORT"
  process-client <&"${fd:?}" &
  # close in parent
  exec {fd}>&-
done
