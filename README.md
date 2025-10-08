# zslsk
zslsk is a client library for the proprietary Soulseek protocol written in Zig. 

currently, nearly all functionality does not work, though the library is under active development.

what has been implemented:
- [x] Library initialization (via `client.connect(HOST, PORT, username, password)`, performs synchronous login then starts async message handler)
- [x] Initial async message parsing (`RoomList`, `PrivilegedUsers`, `ParentMinSpeed`, `ParentSpeedRatio`, `WishlistSearch`, `ExcludedSearchPhrases`)

the current focus of the project is to build out bare minimum functionality, and add more as the project matures. roadmap coming soon.
