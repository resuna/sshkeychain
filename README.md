# sshkeychain
SSHKeychain is a GUI front-end for ssh-agent and ssh-add on Mac OS X.

## My fork

I'm trying to get this updated to 64 bit because Catalina. :(

Turns out it was pre-broken. Seems like it wasn't supposed to make GUI calls from other threads but apparently earlier versions of XCode let it get away with it.
