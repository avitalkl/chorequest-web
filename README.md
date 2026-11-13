# ChoreQuest

A gamified family chore management Progressive Web App (PWA).

Kids complete chores (quests), earn coins, customize avatars, play mini-games, and redeem real-world prizes. Parents create chores, set schedules, approve completions, and manage the family.

## Features

### Kid experience
- Daily/weekly chores with progress tracking
- Coin rewards
- Avatar customization and shop
- Multiple mini-games (memory, slide puzzle, Simon, emoji sudoku, word scramble, and more)
- Real-world prize redemption
- Bilingual support (English + Hebrew)
- Installable as a PWA

### Parent experience
- Create and manage chores (icons, coin values, optional mini-game, daily/weekly schedules)
- Approve or reject completed chores
- Add kids and pair their devices via QR code / link
- Real-world prizes
- Google sign-in
- Family invites
- Bilingual (English + Hebrew)

### Backend
- Supabase (authentication, households, kids, chores, schedules, coin ledger, approvals)

## Project structure

- `/kid` — Kid-facing PWA
- `/parent` — Parent-facing PWA
- `/admin` — Admin view
- `/supabase` — Database migrations and test SQL
- `/vendor` — Supabase client and QR code library

## Running locally

This is a static PWA that talks to Supabase. Serve the folder with any static file server, for example:

```bash
python -m http.server 8000
# or
npx serve .