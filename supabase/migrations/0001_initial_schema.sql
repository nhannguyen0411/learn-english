-- Source table stores original content references
create table public.sources (
  id uuid primary key default gen_random_uuid(),
  source_url text not null,
  title text,
  notes text,
  created_at timestamptz default now()
);

-- Lessons represent each listening exercise
create table public.lessons (
  id uuid primary key default gen_random_uuid(),
  source_id uuid references public.sources(id) on delete set null,
  title text not null,
  transcript text not null,
  audio_url text,
  meta jsonb default '{}'::jsonb,
  created_by uuid references auth.users(id),
  is_private boolean default true,
  created_at timestamptz default now()
);

-- Sentences split from lesson transcript
create table public.sentences (
  id uuid primary key default gen_random_uuid(),
  lesson_id uuid references public.lessons(id) on delete cascade,
  idx int not null,
  text text not null,
  start_sec numeric,
  end_sec numeric
);

-- Key chunks/collocations/phrases
create table public.chunks (
  id uuid primary key default gen_random_uuid(),
  lesson_id uuid references public.lessons(id) on delete cascade,
  text text not null,
  kind text check (kind in ('collocation','phrasal','pattern','idiom','useful')),
  example text,
  notes text
);

-- Auto-generated exercises per lesson
create table public.exercises (
  id uuid primary key default gen_random_uuid(),
  lesson_id uuid references public.lessons(id) on delete cascade,
  kind text check (kind in ('reading_cloze','listening_cloze','speaking','writing')) not null,
  payload jsonb not null,
  created_at timestamptz default now()
);

-- User progress tracking
create table public.user_progress (
  id bigserial primary key,
  user_id uuid references auth.users(id) on delete cascade,
  lesson_id uuid references public.lessons(id) on delete cascade,
  status text check (status in ('not_started','in_progress','completed')) default 'in_progress',
  score jsonb,
  updated_at timestamptz default now()
);

-- SRS items based on selected chunks
create table public.srs_items (
  id bigserial primary key,
  user_id uuid references auth.users(id) on delete cascade,
  chunk_id uuid references public.chunks(id) on delete cascade,
  due_at timestamptz not null,
  interval_days int default 0,
  ease float default 2.5,
  reps int default 0,
  lapses int default 0,
  last_reviewed_at timestamptz
);
create index on public.srs_items (user_id, due_at);

-- Row level security policies
alter table public.lessons enable row level security;
create policy "own_or_private" on public.lessons
for select using (is_private or (auth.uid() = created_by))
with check (auth.uid() = created_by);

alter table public.user_progress enable row level security;
create policy "own_progress" on public.user_progress
for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

alter table public.srs_items enable row level security;
create policy "own_srs" on public.srs_items
for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
