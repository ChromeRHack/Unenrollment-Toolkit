checkforpolicy() {
     #Check for crosh blocked by policy
}

getkeypresses() {
     while True:
          case "$1" in
            '[zxcvbn]') bash /usr/bin/crosh.new
}
checkforpolicy
getkeypresses
