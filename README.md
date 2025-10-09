# zslsk
zslsk is a client library for the proprietary Soulseek protocol written in Zig. 

currently, nearly all functionality does not work, though the library is under active development.

what has been implemented:
- [x] Library initialization (via `client.connect(HOST, PORT, username, password, LISTEN_PORT)`, performs synchronous login then starts async message handler and listener for P2P connections)
- [x] Initial async server message parsing (`RoomList`, `PrivilegedUsers`, `ParentMinSpeed`, `ParentSpeedRatio`, `WishlistSearch`, `ExcludedSearchPhrases`)
- [x] Architecture to handle P2P client messages (currently just `UserInfoMessage`, in and out)

the current focus of the project is to build out bare minimum functionality, and add more as the project matures. roadmap coming soon.
