-- 0000_baseline_schema.sql
-- Schema-only baseline of the EW-TC-CRM production database, read on 2026-11-02.
-- NO DATA. For the STAGING project only. Never run this on production.
--
-- It reproduces production as it is TODAY, including its known weaknesses, so that
-- Step S1 (identity + RLS) is tested against realistic starting conditions:
--   * every CRM table has an "Allow anon ..." policy with USING (true)   -> S1 removes them
--   * system_users is keyed by the plain 4-digit PIN                      -> S1 replaces it
--   * view attendance_cumulative_totals is SECURITY DEFINER               -> S1 fixes it
--   * handle_attendance_tracking() is SECURITY DEFINER, mutable search_path, callable by anon -> S1 fixes it
-- Re-runnable: IF NOT EXISTS / OR REPLACE / DROP POLICY IF EXISTS.

-- ---------- extensions (plpgsql is built in) ----------
create extension if not exists pgcrypto;
create extension if not exists "uuid-ossp";

-- ---------- tables ----------
create table if not exists public.system_users (
  pin text not null,
  name text not null,
  role text not null,
  "avatarColor" text not null,
  constraint system_users_pkey primary key (pin)
);

create table if not exists public.leads (
  id text not null,
  name text not null,
  phone text not null,
  entity text not null,
  platform text not null,
  priority text not null,
  status text not null,
  "inquiryNote" text,
  "addedBy" text not null,
  "assignedAgent" text not null,
  "followUpDue" text,
  "callCenterNote" text,
  "organizerNote" text,
  "organizerNoteUpdatedAt" text,
  "createdAt" text not null,
  "updatedAt" text not null,
  "isBookedForAppointment" boolean not null,
  "statusHistory" jsonb not null,
  "callLogs" jsonb not null,
  "attendanceStatus" text not null default 'Pending'::text,
  "commissionEligible" boolean not null default false,
  "customerId" text,
  constraint leads_pkey primary key (id),
  constraint leads_phone_key unique (phone)
);

create table if not exists public.team_messages (
  id text not null,
  "senderName" text not null,
  "senderRole" text not null,
  "recipientRole" text not null,
  content text not null,
  "timestamp" text not null,
  "isRead" boolean not null,
  "readBy" jsonb not null,
  "threadId" text,
  "expiresAt" text not null,
  constraint team_messages_pkey primary key (id)
);

create table if not exists public.audit_logs (
  id text not null,
  "timestamp" text not null,
  "user" text not null,
  role text not null,
  category text not null,
  action text not null,
  details text not null,
  constraint audit_logs_pkey primary key (id)
);

create table if not exists public.unconverted_contacts (
  id text not null,
  entity text not null,
  platform text not null,
  reason text not null,
  name text,
  phone text,
  "loggedBy" text not null,
  "createdAt" text not null,
  "convertedToLeadId" text,
  constraint unconverted_contacts_pkey primary key (id)
);

create table if not exists public.attendance_sessions (
  id uuid not null default gen_random_uuid(),
  employee_name text not null,
  login_time timestamptz not null,
  last_action_time timestamptz not null,
  logout_time timestamptz,
  active_minutes numeric not null default 0,
  sleep_minutes_raw numeric not null default 0,
  break_minutes numeric not null default 60,
  sleep_minutes_real numeric,
  total_shift_hours numeric,
  status text not null default 'open'::text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint attendance_sessions_pkey primary key (id)
);

create table if not exists public.doctors (
  id text not null,
  name text not null,
  clinic text not null default 'Eye World'::text,
  department text not null default 'Eye World Hospital'::text,
  degree text not null default ''::text,
  specialty text not null default ''::text,
  branch text not null,
  phone text not null default ''::text,
  "consultationFee" text not null default ''::text,
  "isActive" boolean not null default true,
  notes text not null default ''::text,
  "createdAt" text not null,
  "updatedAt" text not null,
  constraint doctors_pkey primary key (id)
);

create table if not exists public.doctor_availability (
  id text not null,
  "doctorId" text not null,
  "dayOfWeek" integer not null,
  "startTime" text not null,
  "endTime" text not null,
  "slotDurationMinutes" integer not null default 30,
  "isActive" boolean not null default true,
  constraint doctor_availability_pkey primary key (id),
  constraint "doctor_availability_dayOfWeek_check" check (("dayOfWeek" >= 0) and ("dayOfWeek" <= 6)),
  constraint "doctor_availability_doctorId_dayOfWeek_key" unique ("doctorId", "dayOfWeek"),
  constraint "doctor_availability_slotDurationMinutes_check" check (("slotDurationMinutes" >= 5) and ("slotDurationMinutes" <= 240)),
  constraint "doctor_availability_doctorId_fkey" foreign key ("doctorId") references public.doctors(id) on delete cascade
);

create table if not exists public.appointments (
  id text not null,
  "leadId" text,
  "customerId" text,
  "patientName" text not null,
  "patientPhone" text not null,
  "doctorId" text not null,
  "doctorName" text not null,
  branch text not null,
  "appointmentDate" text not null,
  "startTime" text not null,
  "endTime" text not null,
  status text not null default 'Pending'::text,
  "bookingSource" text not null default 'Other'::text,
  notes text not null default ''::text,
  "createdBy" text not null,
  "createdAt" text not null,
  "updatedAt" text not null,
  "canceledReason" text,
  constraint appointments_pkey primary key (id),
  constraint appointments_status_check check (status = any (array['Pending'::text,'Confirmed'::text,'Canceled'::text,'Rescheduled'::text,'Completed'::text,'No-Show'::text])),
  constraint "appointments_doctorId_fkey" foreign key ("doctorId") references public.doctors(id)
);

-- ---------- indexes ----------
create index if not exists leads_customer_id_idx on public.leads using btree ("customerId");
create index if not exists idx_attendance_sessions_employee_status on public.attendance_sessions using btree (employee_name, status);
create index if not exists idx_attendance_sessions_login_time on public.attendance_sessions using btree (login_time);
create index if not exists appointments_date_idx on public.appointments using btree ("appointmentDate");
create index if not exists appointments_doctor_date_idx on public.appointments using btree ("doctorId", "appointmentDate");
create unique index if not exists appointments_active_slot_idx on public.appointments using btree ("doctorId", "appointmentDate", "startTime") where (status = any (array['Pending'::text,'Confirmed'::text]));

-- ---------- function + trigger (attendance tracking) ----------
CREATE OR REPLACE FUNCTION public.handle_attendance_tracking()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_session public.attendance_sessions%ROWTYPE;
  v_event_time timestamptz;
  v_gap_minutes numeric;
BEGIN
  v_event_time := NEW.timestamp::timestamptz;

  IF NEW.category = 'Attendance' AND NEW.action = 'Login' THEN

    SELECT * INTO v_session
    FROM public.attendance_sessions
    WHERE employee_name = NEW."user" AND status = 'open'
    ORDER BY login_time DESC
    LIMIT 1;

    IF FOUND THEN
      v_gap_minutes := EXTRACT(EPOCH FROM (v_event_time - v_session.last_action_time)) / 60.0;
      IF v_gap_minutes > 60 THEN
        v_session.sleep_minutes_raw := v_session.sleep_minutes_raw + v_gap_minutes;
      ELSE
        v_session.active_minutes := v_session.active_minutes + v_gap_minutes;
      END IF;

      UPDATE public.attendance_sessions
      SET logout_time = v_session.last_action_time,
          active_minutes = v_session.active_minutes,
          sleep_minutes_raw = v_session.sleep_minutes_raw,
          sleep_minutes_real = GREATEST(v_session.sleep_minutes_raw - v_session.break_minutes, 0),
          total_shift_hours = ROUND(EXTRACT(EPOCH FROM (v_session.last_action_time - v_session.login_time)) / 3600.0, 2),
          status = 'abnormal_close',
          updated_at = now()
      WHERE id = v_session.id;
    END IF;

    INSERT INTO public.attendance_sessions (employee_name, login_time, last_action_time, status)
    VALUES (NEW."user", v_event_time, v_event_time, 'open');

    RETURN NEW;
  END IF;

  IF NEW.category = 'Attendance' AND NEW.action = 'Logout' THEN

    SELECT * INTO v_session
    FROM public.attendance_sessions
    WHERE employee_name = NEW."user" AND status = 'open'
    ORDER BY login_time DESC
    LIMIT 1;

    IF FOUND THEN
      v_gap_minutes := EXTRACT(EPOCH FROM (v_event_time - v_session.last_action_time)) / 60.0;
      IF v_gap_minutes > 60 THEN
        v_session.sleep_minutes_raw := v_session.sleep_minutes_raw + v_gap_minutes;
      ELSE
        v_session.active_minutes := v_session.active_minutes + v_gap_minutes;
      END IF;

      UPDATE public.attendance_sessions
      SET logout_time = v_event_time,
          active_minutes = v_session.active_minutes,
          sleep_minutes_raw = v_session.sleep_minutes_raw,
          sleep_minutes_real = GREATEST(v_session.sleep_minutes_raw - v_session.break_minutes, 0),
          total_shift_hours = ROUND(EXTRACT(EPOCH FROM (v_event_time - v_session.login_time)) / 3600.0, 2),
          status = 'closed',
          updated_at = now()
      WHERE id = v_session.id;
    END IF;

    RETURN NEW;
  END IF;

  SELECT * INTO v_session
  FROM public.attendance_sessions
  WHERE employee_name = NEW."user" AND status = 'open'
  ORDER BY login_time DESC
  LIMIT 1;

  IF FOUND THEN
    v_gap_minutes := EXTRACT(EPOCH FROM (v_event_time - v_session.last_action_time)) / 60.0;
    IF v_gap_minutes > 60 THEN
      UPDATE public.attendance_sessions
      SET sleep_minutes_raw = sleep_minutes_raw + v_gap_minutes,
          last_action_time = v_event_time,
          updated_at = now()
      WHERE id = v_session.id;
    ELSE
      UPDATE public.attendance_sessions
      SET active_minutes = active_minutes + v_gap_minutes,
          last_action_time = v_event_time,
          updated_at = now()
      WHERE id = v_session.id;
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

drop trigger if exists trg_attendance_tracking on public.audit_logs;
create trigger trg_attendance_tracking after insert on public.audit_logs
  for each row execute function public.handle_attendance_tracking();

-- ---------- views ----------
create or replace view public.attendance_daily_report with (security_invoker = on) as
 SELECT employee_name,
    date(login_time) AS work_date,
    round(sum(active_minutes) / 60.0, 2) AS active_hours,
    round(sum(COALESCE(sleep_minutes_real, GREATEST(sleep_minutes_raw - break_minutes, 0::numeric))) / 60.0, 2) AS sleep_hours,
    round(sum(COALESCE(total_shift_hours, 0::numeric)), 2) AS total_shift_hours,
    bool_or(status = 'abnormal_close'::text) AS had_abnormal_close
   FROM attendance_sessions
  WHERE status = ANY (ARRAY['closed'::text, 'abnormal_close'::text])
  GROUP BY employee_name, (date(login_time))
  ORDER BY (date(login_time)) DESC, employee_name;

-- NOTE: SECURITY DEFINER (default) on purpose: identical to production today. S1 must fix it.
create or replace view public.attendance_cumulative_totals as
 SELECT employee_name,
    count(*) FILTER (WHERE status = 'closed'::text) AS clean_sessions,
    count(*) FILTER (WHERE status = 'abnormal_close'::text) AS abnormal_sessions,
    round(sum(total_shift_hours) FILTER (WHERE status = 'closed'::text), 2) AS total_online_hours_reliable,
    round(sum(active_minutes) FILTER (WHERE status = 'closed'::text) / 60.0, 2) AS total_active_hours,
    round(sum(COALESCE(sleep_minutes_real, GREATEST(sleep_minutes_raw - break_minutes, 0::numeric))) FILTER (WHERE status = 'closed'::text) / 60.0, 2) AS total_sleep_hours,
    min(login_time) AS first_seen,
    max(COALESCE(logout_time, last_action_time)) AS last_seen
   FROM attendance_sessions
  GROUP BY employee_name
  ORDER BY (round(sum(total_shift_hours) FILTER (WHERE status = 'closed'::text), 2)) DESC NULLS LAST;

-- ---------- row level security: same as production today (intentionally weak, S1 replaces) ----------
alter table public.system_users enable row level security;
alter table public.leads enable row level security;
alter table public.team_messages enable row level security;
alter table public.audit_logs enable row level security;
alter table public.unconverted_contacts enable row level security;
alter table public.attendance_sessions enable row level security;
alter table public.doctors enable row level security;
alter table public.doctor_availability enable row level security;
alter table public.appointments enable row level security;

drop policy if exists "Allow anon full access" on public.system_users;
create policy "Allow anon full access" on public.system_users for all to anon using (true) with check (true);
drop policy if exists "Allow anon full access" on public.leads;
create policy "Allow anon full access" on public.leads for all to anon using (true) with check (true);
drop policy if exists "Allow anon full access" on public.team_messages;
create policy "Allow anon full access" on public.team_messages for all to anon using (true) with check (true);
drop policy if exists "Allow anon full access" on public.audit_logs;
create policy "Allow anon full access" on public.audit_logs for all to anon using (true) with check (true);
drop policy if exists "Allow anon full access" on public.unconverted_contacts;
create policy "Allow anon full access" on public.unconverted_contacts for all to anon using (true) with check (true);

drop policy if exists "Service role full access" on public.attendance_sessions;
create policy "Service role full access" on public.attendance_sessions for all to public
  using (auth.role() = 'service_role'::text) with check (auth.role() = 'service_role'::text);

drop policy if exists "Allow anon booking access" on public.doctors;
create policy "Allow anon booking access" on public.doctors for all to anon using (true) with check (true);
drop policy if exists "Allow authenticated booking access" on public.doctors;
create policy "Allow authenticated booking access" on public.doctors for all to authenticated using (true) with check (true);
drop policy if exists "Allow anon availability access" on public.doctor_availability;
create policy "Allow anon availability access" on public.doctor_availability for all to anon using (true) with check (true);
drop policy if exists "Allow authenticated availability access" on public.doctor_availability;
create policy "Allow authenticated availability access" on public.doctor_availability for all to authenticated using (true) with check (true);
drop policy if exists "Allow anon appointment access" on public.appointments;
create policy "Allow anon appointment access" on public.appointments for all to anon using (true) with check (true);
drop policy if exists "Allow authenticated appointment access" on public.appointments;
create policy "Allow authenticated appointment access" on public.appointments for all to authenticated using (true) with check (true);

-- Staging seed note: insert only SYNTHETIC test rows (fake names, 010-0000-xxxx phones, test PINs).
-- Never copy real patients, leads, users or PINs from production.
