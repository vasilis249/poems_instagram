-- =====================================================================
-- 0001_init.sql — Αρχικό schema (blackboard της «εταιρείας»)
--
-- Αρχές:
--   * Οι agents ΔΕΝ γράφουν απευθείας εδώ. Ο κώδικας ετοιμάζει το context
--     από τη βάση, καλεί τον agent και γράφει το δομημένο αποτέλεσμα.
--   * Οι guardrails υπάρχουν ΚΑΙ στη βάση (defense in depth): δικαιώματα,
--     PAUSE_ALL, έγκριση και ακρίβεια αποσπασμάτων ελέγχονται με triggers,
--     ακόμα κι αν ο κώδικας έχει bug.
--   * Τα enums είναι text + CHECK, για να αλλάζουν εύκολα με migrations.
--   * Embeddings: vector(1024) (ταιριάζει σε bge-m3 και voyage-3.5).
--     Αν επιλεγεί άλλο μοντέλο, αλλάζει μόνο η διάσταση.
-- =====================================================================

create extension if not exists vector with schema extensions;

-- ---------------------------------------------------------------------
-- Βοηθητικά
-- ---------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger language plpgsql
set search_path = public, extensions as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- ---------------------------------------------------------------------
-- system_flags — kill switch & ρυθμίσεις χρόνου εκτέλεσης
-- (Το PAUSE_ALL ισχύει αν είναι true ΕΙΤΕ στο env ΕΙΤΕ εδώ.
--  Εδώ μπορεί να το γυρίσει ο άνθρωπος από το Telegram με /pause.)
-- ---------------------------------------------------------------------
create table public.system_flags (
  key         text primary key,
  value       jsonb not null,
  updated_at  timestamptz not null default now(),
  updated_by  text not null default 'system'
);

insert into public.system_flags (key, value) values
  ('pause_all',            'false'::jsonb),
  ('autonomy_level',       '"human_gate_all"'::jsonb),   -- human_gate_all | human_gate_flagged | autonomous_high_score
  ('approval_timeout',     '"skip"'::jsonb),              -- skip | reserve
  ('daily_cost_cap_usd',   '2.00'::jsonb),
  ('monthly_cost_cap_usd', '32.00'::jsonb);

-- ---------------------------------------------------------------------
-- people — ποιητές, μεταφραστές, το brand, «δημοτικό»
-- Κανονικοποιημένο: τα έτη θανάτου ζουν σε ΕΝΑ σημείο και τροφοδοτούν
-- και τον υπολογισμό δικαιωμάτων και τις επετείους στο ημερολόγιο.
-- ---------------------------------------------------------------------
create table public.people (
  id            uuid primary key default gen_random_uuid(),
  name          text not null unique,          -- όπως υπογράφεται: «Κ. Π. Καβάφης»
  name_variants text[] not null default '{}',
  kind          text not null default 'person'
                check (kind in ('person', 'brand', 'traditional')),
  birth_date    date,
  birth_year    int,
  death_date    date,
  death_year    int,
  wikidata_id   text,
  notes         text,
  created_at    timestamptz not null default now(),
  constraint people_death_year_matches_date
    check (death_date is null or death_year = extract(year from death_date)::int),
  constraint people_birth_year_matches_date
    check (birth_date is null or birth_year = extract(year from birth_date)::int)
);

-- Το brand και το «δημοτικό» ως οντότητες (το όνομα του brand ενημερώνεται όταν οριστικοποιηθεί).
insert into public.people (name, kind) values
  ('__BRAND__', 'brand'),
  ('Δημοτικό τραγούδι', 'traditional');

-- ---------------------------------------------------------------------
-- poems — η βιβλιοθήκη (Γραμμή Α: κλασικοί, Γραμμή Β: πρωτότυπα)
-- ---------------------------------------------------------------------
create table public.poems (
  id                    uuid primary key default gen_random_uuid(),
  content_line          text not null check (content_line in ('classic', 'original')),
  title                 text,
  text                  text not null,          -- πλήρες κείμενο, Unicode NFC, στίχοι με \n
  text_hash             text generated always as (md5(text)) stored,
  language              text not null default 'el',
  original_language     text,                   -- για μεταφράσεις (π.χ. 'de' για Ρίλκε)
  orthography           text not null default 'monotonic'
                        check (orthography in ('monotonic', 'polytonic', 'mixed')),
  author_id             uuid not null references public.people(id),
  translator_id         uuid references public.people(id),
  first_publication_year int,                   -- για posthumous εκδόσεις (25ετής προστασία εκδότη)
  source_url            text,
  source_edition        text,
  source_retrieved_at   timestamptz,
  source_text_snapshot  text,                   -- αυτούσιο όπως ανακτήθηκε, για diff
  -- Cache. Η αυθεντική τιμή είναι ΠΑΝΤΑ η effective_rights(), που υπολογίζεται
  -- με βάση το τρέχον έτος. Ανανεώνεται nightly με refresh_rights_status().
  rights_status         text not null default 'blocked'
                        check (rights_status in ('public_domain', 'own_original', 'blocked')),
  rights_override       text check (rights_override in ('blocked')),   -- χειροκίνητο μπλόκο
  rights_note           text,
  themes                text[] not null default '{}',
  emotion               text,
  intensity             smallint check (intensity between 1 and 5),
  season                text check (season in ('winter', 'spring', 'summer', 'autumn', 'any')),
  length_lines          int,
  status                text not null default 'draft'
                        check (status in ('draft', 'enriched', 'approved', 'retired', 'rejected')),
  created_by            text not null,          -- 'import:wikisource' | 'agent:brainstormer' | 'human'
  human_edited          boolean not null default false,  -- Γραμμή Β: πέρασε από ανθρώπινη επιμέλεια
  embedding             extensions.vector(1024),
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  constraint poems_text_hash_unique unique (text_hash),
  constraint poems_classic_needs_source
    check (content_line <> 'classic' or source_url is not null),
  constraint poems_original_no_translator
    check (content_line <> 'original' or translator_id is null)
);

create trigger poems_updated_at before update on public.poems
  for each row execute function public.set_updated_at();
create index poems_author_idx   on public.poems (author_id);
create index poems_themes_idx   on public.poems using gin (themes);
create index poems_embedding_idx on public.poems using hnsw (embedding extensions.vector_cosine_ops);

-- ---------------------------------------------------------------------
-- poem_excerpts — αποσπάσματα 2–12 ΣΥΝΕΧΟΜΕΝΩΝ στίχων.
-- Ο trigger εγγυάται ότι το απόσπασμα είναι αυτούσιο κομμάτι του ποιήματος
-- (καμία αλλαγή λέξης στη Γραμμή Α, ούτε κατά λάθος).
-- ---------------------------------------------------------------------
create table public.poem_excerpts (
  id          uuid primary key default gen_random_uuid(),
  poem_id     uuid not null references public.poems(id) on delete cascade,
  line_start  int not null,
  line_end    int not null,
  text        text not null,
  hook_line   text,                       -- πρέπει να είναι αυτούσιος στίχος του ποιήματος
  is_best     boolean not null default false,
  themes      text[] not null default '{}',
  emotion     text,
  intensity   smallint check (intensity between 1 and 5),
  embedding   extensions.vector(1024),
  created_at  timestamptz not null default now(),
  constraint excerpt_line_range
    check (line_start >= 1 and line_end >= line_start and line_end - line_start <= 11),
  unique (poem_id, line_start, line_end)
);

create index poem_excerpts_poem_idx on public.poem_excerpts (poem_id);
create index poem_excerpts_embedding_idx on public.poem_excerpts using hnsw (embedding extensions.vector_cosine_ops);

create or replace function public.check_excerpt_verbatim()
returns trigger language plpgsql
set search_path = public, extensions as $$
declare
  poem_lines text[];
begin
  select string_to_array(p.text, E'\n') into poem_lines
  from public.poems p where p.id = new.poem_id;

  if new.line_end > coalesce(array_length(poem_lines, 1), 0) then
    raise exception 'excerpt lines %-% out of range for poem %', new.line_start, new.line_end, new.poem_id;
  end if;

  if array_to_string(poem_lines[new.line_start:new.line_end], E'\n') <> new.text then
    raise exception 'excerpt text is not a verbatim slice of poem % (lines %-%)',
      new.poem_id, new.line_start, new.line_end;
  end if;

  if new.hook_line is not null and not (new.hook_line = any (poem_lines)) then
    raise exception 'hook_line is not a verbatim line of poem %', new.poem_id;
  end if;

  return new;
end $$;

create trigger poem_excerpts_verbatim before insert or update on public.poem_excerpts
  for each row execute function public.check_excerpt_verbatim();

-- ---------------------------------------------------------------------
-- Δικαιώματα (ν. 2121/1993): 70 έτη από 1/1 του έτους μετά τον θάνατο.
-- Το έτος Y είναι ελεύθερα τα έργα όσων πέθαναν έως και Y-71.
-- ---------------------------------------------------------------------
create or replace function public.pd_cutoff_year(on_date date default current_date)
returns int language sql immutable as $$
  select extract(year from on_date)::int - 71
$$;

create or replace function public.effective_rights(p_poem_id uuid, on_date date default current_date)
returns text language plpgsql stable
set search_path = public, extensions as $$
declare
  p      public.poems;
  a      public.people;
  t      public.people;
  cutoff int := public.pd_cutoff_year(on_date);
begin
  select * into p from public.poems where id = p_poem_id;
  if not found then return 'blocked'; end if;
  if p.rights_override = 'blocked' then return 'blocked'; end if;

  select * into a from public.people where id = p.author_id;

  -- Γραμμή Β: μόνο με υπογραφή brand.
  if p.content_line = 'original' then
    return case when a.kind = 'brand' then 'own_original' else 'blocked' end;
  end if;

  -- Γραμμή Α
  if p.source_url is null then return 'blocked'; end if;
  if a.kind = 'brand' then return 'blocked'; end if;           -- AI κείμενο ποτέ ως «κλασικό»
  if a.kind = 'person' and (a.death_year is null or a.death_year > cutoff) then
    return 'blocked';
  end if;

  -- Πρώτη έκδοση ΜΕΤΑ τη λήξη της προστασίας: 25 έτη για τον εκδότη
  -- (Οδηγία 2006/116, άρθ. 4). Μας αφορά π.χ. για ανέκδοτα που βγήκαν αργά.
  if p.first_publication_year is not null
     and a.death_year is not null
     and p.first_publication_year > a.death_year + 70
     and p.first_publication_year + 25 > cutoff + 70 then
    return 'blocked';
  end if;

  -- Μεταφράσεις: η μετάφραση έχει δικό της copyright.
  if p.translator_id is not null then
    select * into t from public.people where id = p.translator_id;
    if t.kind = 'brand' then
      null;  -- δική μας απόδοση, υπογράφεται «απόδοση: <brand>»
    elsif t.kind <> 'person' or t.death_year is null or t.death_year > cutoff then
      return 'blocked';
    end if;
  elsif p.original_language is not null and p.original_language <> p.language then
    return 'blocked';  -- μεταφρασμένο κείμενο χωρίς γνωστό μεταφραστή
  end if;

  return 'public_domain';
end $$;

create or replace function public.refresh_rights_status()
returns int language plpgsql
set search_path = public, extensions as $$
declare n int;
begin
  update public.poems p
     set rights_status = public.effective_rights(p.id)
   where p.rights_status is distinct from public.effective_rights(p.id);
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- Ορθόδοξο Πάσχα (αλγόριθμος Meeus, Ιουλιανό → Γρηγοριανό, ισχύει 1900–2099)
-- ---------------------------------------------------------------------
create or replace function public.orthodox_easter(y int)
returns date language plpgsql immutable as $$
declare
  a int := y % 4;
  b int := y % 7;
  c int := y % 19;
  d int;
  e int;
begin
  d := (19 * c + 15) % 30;
  e := (2 * a + 4 * b - d + 34) % 7;
  return make_date(y, (d + e + 114) / 31, ((d + e + 114) % 31) + 1) + 13;
end $$;

-- ---------------------------------------------------------------------
-- calendar_events — ελληνικό ημερολόγιο ως δεδομένα
-- ---------------------------------------------------------------------
create table public.calendar_events (
  id             uuid primary key default gen_random_uuid(),
  name           text not null,
  kind           text not null check (kind in (
                   'nameday', 'national', 'religious', 'education', 'season',
                   'cultural', 'poet_birth', 'poet_death', 'social', 'custom')),
  rule_type      text not null check (rule_type in ('fixed', 'easter_offset', 'date')),
  month          smallint check (month between 1 and 12),
  day            smallint check (day between 1 and 31),
  easter_offset  int,
  on_date        date,
  names          text[] not null default '{}',     -- εορτάζοντες (ονομαστικές γιορτές)
  person_id      uuid references public.people(id),
  tone           text,                              -- π.χ. 'πένθιμο', 'γιορτινό', 'νοσταλγικό'
  priority       smallint not null default 3 check (priority between 1 and 5),
  notes          text,
  active         boolean not null default true,
  constraint calendar_rule_fields check (
       (rule_type = 'fixed'         and month is not null and day is not null)
    or (rule_type = 'easter_offset' and easter_offset is not null)
    or (rule_type = 'date'          and on_date is not null))
);

-- Σημ.: ονομαστικές γιορτές που «μετακινούνται» λόγω Πάσχα (π.χ. Αγ. Γεωργίου)
-- χειρίζονται στον κώδικα του calendar module, όχι εδώ.
create or replace function public.events_on(d date)
returns setof public.calendar_events language sql stable
set search_path = public, extensions as $$
  select e.*
  from public.calendar_events e
  where e.active and (
       (e.rule_type = 'fixed'
          and e.month = extract(month from d)::int
          and e.day   = extract(day from d)::int)
    or (e.rule_type = 'easter_offset'
          and public.orthodox_easter(extract(year from d)::int) + e.easter_offset = d)
    or (e.rule_type = 'date' and e.on_date = d))
  order by e.priority desc
$$;

-- ---------------------------------------------------------------------
-- strategy_versions — το strategy.md με ιστορικό
-- ---------------------------------------------------------------------
create table public.strategy_versions (
  id          uuid primary key default gen_random_uuid(),
  version     int not null unique,
  content_md  text not null,
  mix         jsonb not null default '{"classic": 0.35, "original": 0.65}',
  rationale   text not null,
  created_by  text not null,                -- 'agent:ceo' | 'human'
  is_active   boolean not null default false,
  created_at  timestamptz not null default now()
);
create unique index strategy_one_active on public.strategy_versions (is_active) where is_active;

-- ---------------------------------------------------------------------
-- banned_phrases — λίστα κλισέ που μεγαλώνει
-- ---------------------------------------------------------------------
create table public.banned_phrases (
  phrase      text primary key,
  reason      text,
  added_by    text not null default 'human',
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- pipeline_runs & agent_runs — «τι σκέφτηκε η εταιρεία», κόστος, idempotency
-- ---------------------------------------------------------------------
create table public.pipeline_runs (
  id           uuid primary key default gen_random_uuid(),
  flow         text not null check (flow in (
                 'daily', 'weekly', 'monthly', 'community', 'metrics', 'publish', 'ingest')),
  run_key      text not null unique,          -- π.χ. 'daily:2026-11-20' (dry runs: 'dry:<uuid>')
  dry_run      boolean not null default false,
  status       text not null default 'running'
               check (status in ('running', 'succeeded', 'failed', 'skipped', 'paused')),
  started_at   timestamptz not null default now(),
  finished_at  timestamptz,
  error        text,
  summary      jsonb
);

create table public.agent_runs (
  id                  uuid primary key default gen_random_uuid(),
  pipeline_run_id     uuid references public.pipeline_runs(id) on delete set null,
  agent               text not null check (agent in (
                        'ceo', 'brainstormer', 'marketing', 'designer',
                        'editor', 'community_manager', 'analyst')),
  purpose             text not null,          -- π.χ. 'daily_brief', 'text_review', 'classify_comments'
  model               text not null,
  prompt_file         text not null,          -- agents/editor.md
  prompt_sha          text not null,          -- hash του prompt που χρησιμοποιήθηκε
  input               jsonb not null,
  output              jsonb,
  stop_reason         text,
  input_tokens        int,
  output_tokens       int,
  cache_read_tokens   int,
  cache_write_tokens  int,
  cost_usd            numeric(10, 5),
  duration_ms         int,
  error               text,
  created_at          timestamptz not null default now()
);
create index agent_runs_created_idx on public.agent_runs (created_at);
create index agent_runs_pipeline_idx on public.agent_runs (pipeline_run_id);

-- ---------------------------------------------------------------------
-- briefs → candidates → reviews → decisions
-- ---------------------------------------------------------------------
create table public.briefs (
  id                   uuid primary key default gen_random_uuid(),
  brief_date           date not null,
  slot                 text not null default 'feed',     -- 'feed' | 'story_1' | ...
  dry_run              boolean not null default false,
  pipeline_run_id      uuid references public.pipeline_runs(id),
  day_context          jsonb not null,                  -- γιορτές, καιρός, mood, πρόσφατα αποτελέσματα
  target_emotion       text,
  target_audience      text,                            -- «για όποιον…» — ο παραλήπτης του send
  series               text,
  content_line_target  text not null default 'either'
                       check (content_line_target in ('classic', 'original', 'either')),
  avoid                text[] not null default '{}',    -- θέματα/τόνοι προς αποφυγή σήμερα
  notes                text,
  created_at           timestamptz not null default now()
);
create unique index briefs_one_per_slot on public.briefs (brief_date, slot) where not dry_run;

create table public.candidates (
  id                  uuid primary key default gen_random_uuid(),
  brief_id            uuid not null references public.briefs(id) on delete cascade,
  round               smallint not null default 1 check (round between 1 and 3),
  origin              text not null check (origin in ('library', 'generated', 'reserve')),
  poem_id             uuid not null references public.poems(id),
  excerpt_id          uuid references public.poem_excerpts(id),
  intended_recipient  text,                             -- «για τη φίλη που…»
  agent_notes         text,
  created_at          timestamptz not null default now()
);
create index candidates_brief_idx on public.candidates (brief_id);

create table public.reviews (
  id               uuid primary key default gen_random_uuid(),
  candidate_id     uuid references public.candidates(id) on delete cascade,
  post_id          uuid,                                -- για visual reviews (FK παρακάτω)
  stage            text not null check (stage in ('text', 'visual')),
  round            smallint not null default 1,
  -- Έλεγχοι από ΚΩΔΙΚΑ (ο Editor δεν μπορεί να τους παρακάμψει):
  rights_pass      boolean not null,
  quote_exact      boolean,                             -- Γραμμή Α: diff με την πηγή
  similarity_max   numeric(4, 3),
  similar_post_id  uuid,
  -- Κρίση Editor:
  scores           jsonb,                               -- {"stop_power":4, "truth":5, ...}
  avg_score        numeric(3, 2),
  min_score        smallint,
  verdict          text not null check (verdict in ('approve', 'revise', 'reject')),
  feedback         text,
  flags            text[] not null default '{}',        -- 'sensitive_topic', 'near_duplicate', ...
  agent_run_id     uuid references public.agent_runs(id),
  created_at       timestamptz not null default now(),
  constraint reviews_target check (candidate_id is not null or post_id is not null),
  constraint reviews_rights_veto check (rights_pass or verdict = 'reject')
);

create table public.decisions (
  id                        uuid primary key default gen_random_uuid(),
  decision_date             date not null,
  kind                      text not null check (kind in (
                              'daily_pick', 'strategy_update', 'mix_change', 'experiment', 'override')),
  brief_id                  uuid references public.briefs(id),
  chosen_candidate_id       uuid references public.candidates(id),
  considered_candidate_ids  uuid[] not null default '{}',
  rationale                 text not null,
  agent                     text not null,              -- 'ceo' | 'human'
  agent_run_id              uuid references public.agent_runs(id),
  created_at                timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- posts, post_assets, approvals
-- ---------------------------------------------------------------------
create table public.posts (
  id                 uuid primary key default gen_random_uuid(),
  publish_date       date not null,
  slot               text not null default 'feed',
  media_type         text not null check (media_type in ('CAROUSEL', 'IMAGE', 'STORY', 'REEL')),
  dry_run            boolean not null default false,
  candidate_id       uuid references public.candidates(id),
  poem_id            uuid not null references public.poems(id),
  excerpt_id         uuid references public.poem_excerpts(id),
  template_id        text,
  caption            text,
  hashtags           text[] not null default '{}',
  scheduled_at       timestamptz,
  status             text not null default 'draft' check (status in (
                       'draft', 'rendered', 'pending_approval', 'approved',
                       'publishing', 'published', 'failed', 'cancelled', 'skipped')),
  approval_status    text not null default 'pending'
                     check (approval_status in ('pending', 'approved', 'rejected', 'timeout', 'not_required')),
  is_reserve         boolean not null default false,  -- «εφεδρεία»: εγκεκριμένο, μη χρονο-εξαρτώμενο
  reserve_expires_on date,
  editor_score       numeric(3, 2),
  flags              text[] not null default '{}',
  series             text,
  experiment_id      uuid,
  ig_container_id    text,
  ig_media_id        text unique,
  permalink          text,
  published_at       timestamptz,
  publish_attempts   int not null default 0,
  last_error         text,
  embedding          extensions.vector(1024),           -- του κειμένου που δημοσιεύτηκε
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

-- Idempotency: το πολύ ένα «ζωντανό» post ανά ημέρα/slot (εκτός dry-run & εφεδρείας).
create unique index posts_one_live_per_slot on public.posts (publish_date, slot)
  where not dry_run and not is_reserve and status not in ('cancelled', 'skipped', 'failed');
create index posts_status_idx on public.posts (status, scheduled_at);
create index posts_poem_idx on public.posts (poem_id);
create index posts_embedding_idx on public.posts using hnsw (embedding extensions.vector_cosine_ops);

alter table public.reviews
  add constraint reviews_post_fk foreign key (post_id) references public.posts(id) on delete cascade;

-- Τελευταία γραμμή άμυνας: τίποτα δεν περνά σε 'publishing' χωρίς
-- δικαιώματα, έγκριση και με PAUSE_ALL ανενεργό.
create or replace function public.guard_publish()
returns trigger language plpgsql
set search_path = public, extensions as $$
declare
  r text;
begin
  if new.status = 'publishing' and old.status is distinct from 'publishing' then
    if new.dry_run then
      raise exception 'post %: dry-run posts cannot be published', new.id;
    end if;
    if exists (select 1 from public.system_flags where key = 'pause_all' and value = 'true'::jsonb) then
      raise exception 'post %: PAUSE_ALL is active', new.id;
    end if;
    r := public.effective_rights(new.poem_id);
    if r not in ('public_domain', 'own_original') then
      raise exception 'post %: rights check failed (poem %, status %)', new.id, new.poem_id, r;
    end if;
    if new.approval_status not in ('approved', 'not_required') then
      raise exception 'post %: not approved (approval_status=%)', new.id, new.approval_status;
    end if;
    if new.approval_status = 'not_required'
       and not exists (select 1 from public.system_flags
                       where key = 'autonomy_level' and value <> '"human_gate_all"'::jsonb) then
      raise exception 'post %: human approval required at current autonomy level', new.id;
    end if;
  end if;
  new.updated_at := now();
  return new;
end $$;

create trigger posts_guard_publish before update on public.posts
  for each row execute function public.guard_publish();

create table public.post_assets (
  id              uuid primary key default gen_random_uuid(),
  post_id         uuid not null references public.posts(id) on delete cascade,
  kind            text not null check (kind in ('feed_slide', 'story', 'reel_cover', 'reel_video')),
  position        smallint not null default 1,
  width           int not null,
  height          int not null,
  storage_bucket  text not null,               -- 'renders' (private) | 'ig-public'
  storage_path    text not null,
  public_url      text,                        -- μόνο τη στιγμή της δημοσίευσης
  sha256          text,
  checks          jsonb,                       -- overflow, contrast, glyph fallback, vision notes
  created_at      timestamptz not null default now(),
  unique (post_id, kind, position)
);

create table public.approvals (
  id                   uuid primary key default gen_random_uuid(),
  post_id              uuid not null references public.posts(id) on delete cascade,
  channel              text not null default 'telegram',
  telegram_chat_id     bigint,
  telegram_message_id  bigint,
  requested_at         timestamptz not null default now(),
  deadline_at          timestamptz not null,
  responded_at         timestamptz,
  response             text check (response in ('approve', 'edit', 'regenerate', 'reject', 'timeout')),
  edit_text            text,
  responder            text
);
create index approvals_open_idx on public.approvals (deadline_at) where responded_at is null;

-- ---------------------------------------------------------------------
-- metrics
-- ---------------------------------------------------------------------
create table public.metrics (
  id                  uuid primary key default gen_random_uuid(),
  post_id             uuid not null references public.posts(id) on delete cascade,
  captured_at         timestamptz not null default now(),
  window_label        text not null check (window_label in ('24h', '7d', '28d', 'adhoc')),
  reach               int,
  views               int,
  saves               int,
  shares              int,          -- το API δεν δίνει ξεχωριστά τα DM sends· shares = καλύτερο proxy
  comments            int,
  likes               int,
  follows             int,
  profile_visits      int,
  total_interactions  int,
  raw                 jsonb
);
create unique index metrics_one_per_window on public.metrics (post_id, window_label)
  where window_label <> 'adhoc';

create table public.account_daily_metrics (
  metric_date     date primary key,
  followers       int,
  reach           int,
  profile_views   int,
  raw             jsonb,
  captured_at     timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- comments — Community Manager
-- GDPR: τα σχόλια μπορεί να περιέχουν δεδομένα υγείας (ειδική κατηγορία).
-- Πολιτική διατήρησης: purge_old_comments() σβήνει username/κείμενο μετά από 90 ημέρες.
-- ---------------------------------------------------------------------
create table public.comments (
  id                     uuid primary key default gen_random_uuid(),
  ig_comment_id          text not null unique,
  post_id                uuid references public.posts(id) on delete cascade,
  parent_ig_comment_id   text,
  ig_username            text,
  text                   text,
  commented_at           timestamptz,
  fetched_at             timestamptz not null default now(),
  category               text check (category in (
                           'appreciation', 'question', 'personal_share',
                           'spam', 'toxic', 'distress', 'off_limits', 'other')),
  category_confidence    numeric(3, 2),
  reply_text             text,
  reply_ig_comment_id    text,
  action                 text not null default 'pending' check (action in (
                           'pending', 'replied', 'hidden', 'escalated', 'ignored', 'awaiting_human')),
  needs_human            boolean not null default false,
  human_notified_at      timestamptz,
  handled_by             text,
  handled_at             timestamptz,
  agent_run_id           uuid references public.agent_runs(id),
  purged                 boolean not null default false
);
create index comments_pending_idx on public.comments (action) where action in ('pending', 'awaiting_human');
create index comments_needs_human_idx on public.comments (needs_human) where needs_human;

create or replace function public.purge_old_comments(keep_days int default 90)
returns int language plpgsql
set search_path = public, extensions as $$
declare n int;
begin
  update public.comments
     set ig_username = null, text = null, reply_text = null, purged = true
   where not purged
     and fetched_at < now() - make_interval(days => keep_days)
     and action <> 'awaiting_human';
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- ideas — θέματα από σχόλια / υποθέσεις Analyst (ΠΟΤΕ αυτούσια σχόλια)
-- ---------------------------------------------------------------------
create table public.ideas (
  id          uuid primary key default gen_random_uuid(),
  source      text not null check (source in ('comment', 'analyst', 'ceo', 'human')),
  source_ref  uuid,
  theme       text not null,
  note        text,
  status      text not null default 'open' check (status in ('open', 'used', 'dropped')),
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Trends & benchmarks
-- ---------------------------------------------------------------------
create table public.hashtag_queries (
  id             uuid primary key default gen_random_uuid(),
  hashtag        text not null,                 -- χωρίς '#', πεζά
  ig_hashtag_id  text,
  queried_at     timestamptz not null default now(),
  result         jsonb
);
create index hashtag_queries_time_idx on public.hashtag_queries (queried_at);

-- Όριο Meta: 30 μοναδικά hashtags ανά κυλιόμενο 7ήμερο.
create view public.v_hashtag_budget as
select
  count(distinct hashtag)                       as used_last_7d,
  greatest(0, 30 - count(distinct hashtag))     as remaining,
  array_agg(distinct hashtag)                   as hashtags
from public.hashtag_queries
where queried_at > now() - interval '7 days';

create table public.competitors (
  id           uuid primary key default gen_random_uuid(),
  ig_username  text not null unique,
  ig_user_id   text,
  category     text,                            -- 'poetry' | 'books' | 'psychology' | 'aesthetic'
  notes        text,
  active       boolean not null default true,
  created_at   timestamptz not null default now()
);

create table public.competitor_snapshots (
  id             uuid primary key default gen_random_uuid(),
  competitor_id  uuid not null references public.competitors(id) on delete cascade,
  captured_at    timestamptz not null default now(),
  followers      int,
  media_count    int,
  recent_media   jsonb
);

create table public.experiments (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  kind        text not null check (kind in ('format', 'theme', 'time', 'template', 'caption')),
  hypothesis  text not null,
  variants    jsonb not null,
  starts_on   date,
  ends_on     date,
  status      text not null default 'proposed'
              check (status in ('proposed', 'approved', 'running', 'done', 'dropped')),
  result      jsonb,
  created_by  text not null,
  created_at  timestamptz not null default now()
);
alter table public.posts
  add constraint posts_experiment_fk foreign key (experiment_id) references public.experiments(id);

-- ---------------------------------------------------------------------
-- integration_tokens — μόνο metadata· το ίδιο το token ζει στο Supabase Vault
-- ---------------------------------------------------------------------
create table public.integration_tokens (
  provider         text primary key,           -- 'instagram'
  vault_secret_id  uuid not null,
  expires_at       timestamptz,
  refreshed_at     timestamptz,
  scopes           text[] not null default '{}'
);

-- ---------------------------------------------------------------------
-- Αναζήτηση & ομοιότητα
-- ---------------------------------------------------------------------

-- Υποψήφια αποσπάσματα για ένα brief: μόνο εγκεκριμένα, με έγκυρα δικαιώματα,
-- και όχι ποιήματα που δημοσιεύτηκαν τις τελευταίες N ημέρες.
create or replace function public.search_excerpts(
  q               extensions.vector(1024),
  k               int default 20,
  line_filter     text default null,            -- 'classic' | 'original' | null
  cooldown_days   int default 180
)
returns table (excerpt_id uuid, poem_id uuid, similarity float)
language sql stable
set search_path = public, extensions as $$
  select e.id, p.id, 1 - (e.embedding <=> q)
  from public.poem_excerpts e
  join public.poems p on p.id = e.poem_id
  where e.embedding is not null
    and p.status = 'approved'
    and p.rights_status in ('public_domain', 'own_original')
    and (line_filter is null or p.content_line = line_filter)
    and not exists (
      select 1 from public.posts po
      where po.poem_id = p.id and po.status = 'published'
        and po.published_at > now() - make_interval(days => cooldown_days))
  order by e.embedding <=> q
  limit k
$$;

create or replace function public.similar_posts(q extensions.vector(1024), k int default 5)
returns table (post_id uuid, similarity float)
language sql stable
set search_path = public, extensions as $$
  select id, 1 - (embedding <=> q)
  from public.posts
  where embedding is not null and status = 'published'
  order by embedding <=> q
  limit k
$$;

-- ---------------------------------------------------------------------
-- Views για dashboard / Analyst / cost cap
-- ---------------------------------------------------------------------
create view public.v_daily_cost as
select (created_at at time zone 'Europe/Athens')::date as day,
       agent,
       count(*)                          as runs,
       sum(input_tokens)                 as input_tokens,
       sum(output_tokens)                as output_tokens,
       sum(cost_usd)                     as cost_usd
from public.agent_runs
group by 1, 2;

create view public.v_post_performance as
select p.id as post_id, p.publish_date, p.media_type, p.template_id, p.series,
       po.content_line, p.editor_score,
       m.window_label, m.reach, m.saves, m.shares, m.comments, m.likes, m.follows,
       round(m.saves::numeric  / nullif(m.reach, 0), 4) as saves_per_reach,
       round(m.shares::numeric / nullif(m.reach, 0), 4) as shares_per_reach
from public.posts p
join public.poems po on po.id = p.poem_id
left join public.metrics m on m.post_id = p.id and m.window_label in ('24h', '7d')
where p.status = 'published';

-- ---------------------------------------------------------------------
-- RLS: ενεργό παντού, χωρίς policies → πρόσβαση μόνο με service role.
-- Το dashboard (Φάση 2) θα πάρει δικές του policies.
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array[
    'system_flags', 'people', 'poems', 'poem_excerpts', 'calendar_events',
    'strategy_versions', 'banned_phrases', 'pipeline_runs', 'agent_runs',
    'briefs', 'candidates', 'reviews', 'decisions', 'posts', 'post_assets',
    'approvals', 'metrics', 'account_daily_metrics', 'comments', 'ideas',
    'hashtag_queries', 'competitors', 'competitor_snapshots', 'experiments',
    'integration_tokens']
  loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

-- Views: εκτέλεση με τα δικαιώματα του καλούντος (όχι του owner)
alter view public.v_hashtag_budget   set (security_invoker = on);
alter view public.v_daily_cost       set (security_invoker = on);
alter view public.v_post_performance set (security_invoker = on);

-- ---------------------------------------------------------------------
-- Storage buckets (Supabase). 'renders' ιδιωτικό· 'ig-public' δημόσιο,
-- αρχεία μπαίνουν εκεί ΜΟΝΟ τη στιγμή της δημοσίευσης και σβήνονται μετά.
-- ---------------------------------------------------------------------
do $$
begin
  if exists (select 1 from information_schema.tables
             where table_schema = 'storage' and table_name = 'buckets') then
    insert into storage.buckets (id, name, public) values
      ('renders', 'renders', false),
      ('ig-public', 'ig-public', true)
    on conflict (id) do nothing;
  end if;
end $$;
