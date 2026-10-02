# StudentHub (Supabase edition)
All data (accounts, actions, assignments, submissions, notifications) is stored in your Supabase Postgres database.

## Setup
1. Create a project at supabase.com.
2. SQL Editor > paste `supabase/schema.sql` > Run.
3. Change the invite codes (staff/admin sign-up) in the SQL Editor:
   `update app_settings set value='YOUR-STAFF-CODE' where key='staff_invite';` (same for `admin_invite`).
4. Authentication > Providers > Email: turn off "Confirm email" while testing (or keep it on and confirm by email).
5. Authentication > URL Configuration: set Site URL to your hosted link (and `http://localhost:5500` for local tests).
6. Settings > API: copy the Project URL and the `anon` public key into the top of the script in `index.html`
   (`SB_URL`, `SB_KEY`). Never put the `service_role` key in the page.

## Run
Local: open the folder in VS Code and use Live Server (`index.html`). Hosted: push the folder to GitHub, then Settings > Pages > main / root.
Open the link on a phone, add it to the Home Screen, and allow notifications.

## Texts (SMS)
Texts are queued in `sms_outbox`. To send them, deploy `supabase/functions/send-sms` with your Twilio credentials (see the file header).

## Security notes
Roles are decided in the database from the invite codes. Students can only read their own rows (row level security). Submitting, publishing and reminders run through database functions that check who is calling.

## Not built yet
Staff verification screen, audit log page, department/settings admin pages, Google Forms sync, scheduled automatic reminders, push when the app is closed.
