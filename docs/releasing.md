# Making a release

A release is what servers install with `./server.sh update`, and it is posted to the Discord
releases channel. Everything happens on the GitHub website: nothing to install, any computer works
(Windows too).

## Before: changes on main

Every change comes in through a pull request into `main` (see [Development](development.md)). Its
text becomes part of the release notes, so fill in the template with short bullet points for
players and server owners. Nothing goes out to servers until you make a release.

## A normal release (one click)

1. Open the repository on GitHub and click **Actions**.
2. On the left, click **Release**.
3. On the right, click **Run workflow**. A small form opens:

   | Field | What to pick |
   |---|---|
   | **Version step** | `patch` for fixes, `minor` for new features, `major` for a big update |
   | **Exact version** | leave empty |
   | **Review first** | leave unticked |

4. Click the green **Run workflow** button.

After about a minute the release is on GitHub (**Releases**, on the right of the repository page)
and in the Discord releases channel. Servers get it with `./server.sh update`.

The version counts on from the last release: after 0.34.0, `patch` makes 0.34.1, `minor` 0.35.0
and `major` 1.0.0.

## Your own version number

Type it into **Exact version**, e.g. `1.0.0`. It must be higher than the last release. The
**Version step** is ignored then.

## Your own text

Tick **Review first**. The release is then made as a **draft**: servers and Discord don't see it
yet.

1. When the run is done, open **Releases**: the draft is at the top. (The run's summary has the
   link too.)
2. Click the pencil (**Edit**). The text is filled in with the pull requests since the last
   release: change it, shorten it or write your own. Images can be dropped in.
3. Click **Publish release**.

Only now is it posted to Discord, with your text, and servers can install it.

Changed your mind? Delete the draft (**Edit → Delete**). Running the workflow again for the same
version replaces an unpublished draft.

## If something goes wrong

- **"Nothing to release" (a note, the run is green):** nothing changed in the mod since the last
  release (only docs or tools). Nothing to do.
- **The run is red:** a test failed or the exact version was not higher than the last release.
  Click the run, then the red step, to read why. Nothing was released; fix it and run it again.
- **Nothing in Discord:** check the repository secret `DISCORD_RELEASE_WEBHOOK` (Settings →
  Secrets and variables → Actions). It holds the webhook URL of the releases channel (in Discord:
  Edit Channel → Integrations → Webhooks → Copy Webhook URL).
- **A text in Discord is wrong:** edit or delete the message in Discord by hand. Editing the
  release on GitHub later doesn't change the Discord post.
