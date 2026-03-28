# zslsk

zslsk is a client-server library for the proprietary Soulseek protocol written in Zig.

It uses [zio](https://github.com/lalinsky/zio) under the hood for efficient asynchronous I/O.

The library is under active development, and many features are currently missing.

> [!CAUTION]
> zslsk is currently not intended for use in production. There are likely vulnerabilities that exist in the codebase that may put your system at risk.

## Status

> [!WARNING]
> zslsk is only confirmed to build with Zig version `0.16.0-dev.2459+37d14a4f3`. I know this is suboptimal, but [this issue](https://github.com/lumaaaaaa/zslsk/issues/24) explains what the situation is and track the status of it. The goal is to move to Zig 0.16.0 when it is released.

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
  - `UserInterests`
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
  - `TransferResponse`
  - `QueueUpload`
- [x] File message parse/write:
  - `FileTransferInit`
  - `FileOffset`

The current focus of the project is to build out bare minimum functionality, and add more as the project matures. Roadmap coming soon.
