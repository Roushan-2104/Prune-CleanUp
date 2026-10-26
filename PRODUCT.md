# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Stack

Flutter Windows desktop app (no web build), Material 3 widgets. Mac and iPhone support come later. The platform value above only means "not native mobile": the app follows Windows desktop conventions (mouse and keyboard, large window, no touch-first patterns).

## Users

People with huge phone galleries (10k–100k+ items): chronically online, techie, global (English UI). When their Android phone runs out of space, they plug it into their Windows laptop for one deep clean. General, non-technical users are explicitly not the target.

## Product Purpose

Declutter reads the phone over USB, checks photos, screenshots, videos and files on the laptop, and shows what is safe to remove, with proof. The user reviews on the big screen, chooses, and Declutter moves the chosen items to the phone's Trash (optional backup first), with Undo. Success means the user frees a lot of space in one sitting and never loses something they wanted.

## Positioning

Every suggestion carries its evidence: the photo shown next to the copy it matched, "How we know" facts for each item, and only items Declutter is sure about pre-ticked. Screenshots are grouped by what they actually are (chats by person and app, payments by app, other screens by app or website), not generic buckets.

## Operating Context

- Primary flow (confirmed): the first screen leads with one safe pick, "You can free X GB", made only of sure items. The user glances through it by group, adjusts, then cleans. Browsing everything else is secondary.
- Phone connected over USB with USB debugging. Reading takes seconds; the photo check takes minutes on a first run and runs in the background while results appear batch by batch.
- Later visits only check what is new or changed.
- Keyboard shortcuts exist in review (arrows, Space to tick, Ctrl+A, Esc).

## Capabilities and Constraints

- Read-only until Clean: no command that changes the phone runs before the user approves a clean-up. If a process stops midway, the phone is undisturbed.
- Groups: payment screenshots (by app), chat screenshots (by person and app), other screenshots (by app or site), blurry photos, similar photos and exact duplicates (always shown with the kept copy), WhatsApp sent copies, short accidental clips, screen recordings, large videos, old installers, old voice notes, old documents, caches.
- Tiers: "sure" items are pre-ticked; "maybe" items are shown unticked; anything less certain is never shown.
- Clean moves items to the phone's Trash (30-day recovery) or deletes hidden files; optional backup to the laptop; Undo restores.
- Videos play inside the app, streamed from the phone.
- Pricing, cloud (Google Photos) cleanup and MTP mode are undecided or deferred.

## Brand Commitments

Name: Declutter (final). Personal data stays on the laptop.

## Evidence on Hand

No testimonials, customers or benchmarks yet; do not invent any. Real measurements from the builder's own phone exist (59k files, 16.5k images checked) but are private test data, not marketing claims.

## Product Principles

1. Never lose a good photo. A wrong pick costs more trust than a missed one.
2. Show, don't claim: every suggestion carries its evidence.
3. The phone is untouched until the user says Clean.
4. One sitting, deep clean. Not a weekly habit.
