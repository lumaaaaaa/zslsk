# zslsk

zslsk is a client-server library for the proprietary Soulseek protocol written in Zig.

It uses [zio](https://github.com/lalinsky/zio) under for efficient asynchronous I/O.

The library is under active development, and many features are currently missing.

## Status

- [x] Basic app (in `main.zig`) demonstrating use of library with following commands:
    - `download`
    - `filelist`
    - `msg`
    - `search`
    - `userinfo`
    - `exit`
- [x] Asynchronous library initialization (via `client.run(rt, HOST, PORT, username, password, LISTEN_PORT)`
- [x] Server message parse/write:
    - `Login`
    - `SetWaitPort`
    - `GetPeerAddress`
    - `ConnectToPeer`
    - `MessageUser`
    - `MessageAcked`
    - `FileSearch`
    - `RoomList`
    - `PrivilegedUsers`
    - `ParentMinSpeed`
    - `ParentSpeedRatio`
    - `WishlistSearch`
    - `ExcludedSearchPhrases`
    - `UploadSpeed`
- [x] Peer message parse/write:
    - `PeerInit`
    - `PierceFireWall`
    - `GetSharedFileList`
    - `SharedFileList`
    - `FileSearchResponse`
    - `GetUserInfo`
    - `UserInfo`
    - `TransferRequest`
    - `QueueUpload`

The current focus of the project is to build out bare minimum functionality, and add more as the project matures. Roadmap coming soon.
