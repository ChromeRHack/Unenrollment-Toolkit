#!/bin/bash

args() {
  printf "%s" options:
  while getopts a:b:c:d:e:f:g:h:i:j:k:l:m:n:o:p:q:r:s:t:u:v:w:x:y:z: OPTION "$@"; do
    printf " -%s '%s'" $OPTION $OPTARG
  done
  shift $((OPTIND - 1))
  echo
}

args
./tpmc "$@"

