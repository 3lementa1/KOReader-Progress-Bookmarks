This is a user patch for KOReader made with ChatGPT Codex. It changes the appearance of books for more realistic depictions of book length and progress.

<img width="536" height="724" alt="Cover View small_2026-11-06_113711" src="https://github.com/user-attachments/assets/c1beddd5-0bed-4ca1-86ad-6da19897de08" /> <img width="536" height="724" alt="Spine View large_Screenshot_2026-11-06_144414" src="https://github.com/user-attachments/assets/81372ff9-31de-4df9-96a4-12bb9553caea" />

Features:

-Adds reading-progress bookmarks to Bookshelf’s Cover View and face-out Spine View.
-Tracks progress vertically, horizontally, or both, with controls for bookmark visibility, position, length, thickness, colour, and detail.
-Adds adjustable page-line count and binding/spine rendering options.
-Customizes what is included in spine text, including title, author, and series index display, font, size, colour, and overflow options.
-Includes Cover View and Spine View settings, with independent enable toggles and default-reset options.
-Adds a GitHub update checker that can install the latest stable release, after confirmation, while saving a backup.


Install `2-bookshelf-progress-bookmark.lua` by copying it from Releases on this page into `koreader/patches/`, then restart KOReader.


This patch draws an overlay on book covers in Bookshelf with a spine showing book info, and pages over top that indicate how long the book is. It then draws a bookmark that takes the place of a classic progress bar. The bookmark sits vertically in the page that you are on, just like a real bookmark would. It also moves across horizontally like a classic progress bar so that you can still easily see how far you are in a shorter book. The length, thickness and colour of the bookmark are adjustable, and I might add functionality later to select a custom bookmark image from a png. 
The spine is drawn by copying a section of the cover. The thickness, font and colour of the spine text is adjustable. 
You can toggle this for Cover View and Spine View separately. Spine mode also has options for making the spine text on Spine Only books match the user-defined spine font. You can use this option to customize spine text in Spine View whether or not you use the bookmark functionality.

Features:
Spine
Give your books a distinctive, physical-book look with customizable bindings and spine text.
Adjustable binding widths — Choose Thin, Medium, or Thick bindings, with separate controls for Cover View and Spine View.
Custom spine text — Display the book's title, author, and series index.
Text customization — Adjust text size, colour, and font matching.
Flexible title layout — Choose between truncating long titles or allowing them to wrap onto a second line.
Series indices — Multi-digit series numbers follow the spine's orientation, while single-digit indices sit neatly at the foot.
Page stack customization — Adjust how many pages appear on each line, with up to six lines of page detail.
Bookmark
Keep track of your reading with a customizable progress bookmark.
Flexible tracking — Follow your progress vertically, horizontally, or in both directions.
Adjustable thickness — Choose Thin, Medium, or Thick, with independent settings for each view.
Custom lengths — Configure bookmark length presets to suit your preferred appearance.
Colour options — Customize the bookmark's colour.
Bookmark details — Toggle additional visual details on or off.
View-specific settings — Cover View and Spine View can each have their own bookmark behaviour and appearance.

This is going to work best if you disable the icons for favourites, reading bookmark and spine mode drop shadow, with square corners, and hardcover style. My setup might also involve other settings I don't remember so YMMV and let me know if anything looks weird.
I might add functionality later to select a custom bookmark image from a png as well.

I started working on this idea this Spring when I was editing other people's code line-by-line with ChatGPT and having to do manual updates to several plugin files every time there was an update. This Fall I was given a (still very old) computer that can actually run Codex and I've been able to (get AI to) turn it into a proper patch, so now I am sharing it in case anyone else is interested. I only use Bookshelf now so this is Bookshelf-exclusive at the moment, but I can share the old Project:Title patch and could probably port to SimpleUI and ZenOS if there is interest. Obviously this is all open-source too so feel free to play around with it.

I made the original version for Project:Title which I really loved for the idea of progress bars that are different sizes depending on the size of the book. Project:Title by u/joshua-cant ( https://github.com/joshuacant/ProjectTitle )
This was originally based on the RealBooks patch by u/ReaLx3m which made realistic visual book length a reality and made me want to take progress bars into this visual language ( https://www.reddit.com/r/koreader/comments/1sswzgo/real_books_for_koreader_with_visual_page_count/ ). 
Bookshelf is my current favourite UI done by u/AndyHazz. This really brought the real book feeling home for me by making it feel like I can skim through my library, peek at the back of some books, and now even sort them into box sets. ( https://www.reddit.com/r/koreader/comments/1xn8y0q/bookshelf_63x_date_night/ ) 
Thank you to all these developers and thank you to all the developers of KOReader, which has helped me read more and been very fun to work with.
I just made this for myself and I've never uploaded anything to Github before so please let me know if you have any requests or suggestions.



## Updating

Use **Check for updates** in Progress Bookmarks Patch Settings to check the latest stable GitHub release. The updater installs only after confirmation, verifies the release version, patch filename, and Lua syntax, saves a versioned backup beside the patch, and asks you to restart KOReader.
