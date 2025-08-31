# Kế hoạch chi tiết (Markdown) — App học tiếng Anh từ DailyDictation (MVP thủ công)

> **Các quyết định đã chốt**
> 1) **Nhập dữ liệu**: thủ công (Paste URL/transcript + link/Upload audio).  
> 2) **Chấm điểm Speaking/Writing**: chấp nhận bản MVP (ASR + rule-based, không phụ thuộc LLM).  
> 3) **Listening Cloze mặc định**: **2–3 từ** (có thể chọn 1 từ / cả câu / cả bài).

---

## 1) Kiến trúc tổng quan

- **Web**: React 19 + Vite + TypeScript + Tailwind + **shadcn/ui** (Radix).  
- **State**: TanStack Query (server state), Zustand/Context (UI pref).  
- **Backend**: **Supabase** (Auth, Postgres, Storage, Edge Functions).  
- **Audio**: phát trực tiếp từ URL/Storage; cache nhẹ (PWA).  
- **Scoring**:  
  - Listening: so khớp văn bản (tolerance lỗi chính tả/caps).  
  - Speaking: **Web Speech API** → tokenization → similarity (WER / cosine TF-IDF).  
  - Writing: **chunk-coverage check** + rule-based gợi ý “native-like” (không LLM ở MVP).
- **SRS**: SM-2 rút gọn (due_at, interval, ease, reps, lapses).  
- **Triển khai**: Vercel (web) + Supabase (DB/Functions).

---

## 2) Cấu trúc thư mục (Frontend)

```
src/
  app/               # routes (react-router)
    auth/
    home/
    library/
    lesson/[id]/     # tabs: reading/listening/speaking/writing/review
    review/
    tests/
    importer/
    settings/
  components/
    lesson/
    review/
    ui/              # shadcn components wrapper
  hooks/
  lib/
    supabase.ts
    speech.ts       # Web Speech helpers
    text.ts         # tokenization, similarity, cloze utils
    srs.ts          # SM-2 helpers
  store/
  types/
  styles/
```

---

## 3) Lộ trình thực thi (Step-by-step)

### M0 — Bootstrap dự án (0.5–1 ngày)
- Tạo repo, **pnpm** workspace.  
- Vite + React 19 + TS: `pnpm create vite` → react-ts.  
- Tailwind + shadcn/ui: cài đặt, cấu hình theme, font.  
- ESLint/Prettier/Husky + Vitest + Playwright.  
- Tạo `supabase.ts` (client), `.env` mẫu.

**Mục tiêu chấp nhận**  
- App chạy được, có layout base, dark/light, bottom nav (mobile) + header (desktop).  

---

### M1 — Supabase & schema (1–1.5 ngày)

#### 1.1 Bảng dữ liệu (SQL)
```sql
-- Nguồn (giữ URL gốc để tôn trọng bản quyền)
create table public.sources (
  id uuid primary key default gen_random_uuid(),
  source_url text not null,
  title text,
  notes text,
  created_at timestamptz default now()
);

-- Bài học (mỗi bài nghe)
create table public.lessons (
  id uuid primary key default gen_random_uuid(),
  source_id uuid references public.sources(id) on delete set null,
  title text not null,
  transcript text not null,         -- toàn bài
  audio_url text,                   -- có thể là storage/public url
  meta jsonb default '{}'::jsonb,   -- tags: level/topic
  created_by uuid references auth.users(id),
  is_private boolean default true,  -- MVP: học cá nhân
  created_at timestamptz default now()
);

-- Câu (tách từ transcript)
create table public.sentences (
  id uuid primary key default gen_random_uuid(),
  lesson_id uuid references public.lessons(id) on delete cascade,
  idx int not null,
  text text not null,
  start_sec numeric, -- optional thủ công
  end_sec numeric
);

-- Chunk / collocation / phrase quan trọng
create table public.chunks (
  id uuid primary key default gen_random_uuid(),
  lesson_id uuid references public.lessons(id) on delete cascade,
  text text not null,
  kind text check (kind in ('collocation','phrasal','pattern','idiom','useful')),
  example text,
  notes text
);

-- Bài tập sinh tự động theo lesson
create table public.exercises (
  id uuid primary key default gen_random_uuid(),
  lesson_id uuid references public.lessons(id) on delete cascade,
  kind text check (kind in ('reading_cloze','listening_cloze','speaking','writing')) not null,
  payload jsonb not null,    -- schema xem phần Data Contracts
  created_at timestamptz default now()
);

-- Tiến độ người dùng
create table public.user_progress (
  id bigserial primary key,
  user_id uuid references auth.users(id) on delete cascade,
  lesson_id uuid references public.lessons(id) on delete cascade,
  status text check (status in ('not_started','in_progress','completed')) default 'in_progress',
  score jsonb,          -- điểm chi tiết từng kỹ năng
  updated_at timestamptz default now()
);

-- SRS: item là CHUNK đã chọn
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
```

#### 1.2 RLS (rút gọn)
```sql
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
```

**Mục tiêu chấp nhận**  
- Migration chạy OK.  
- Bảng/Policy tạo xong; insert thử 1 record thành công.

---

### M2 — Edge Functions (2–3 ngày)

#### 2.1 `import-from-manual`
- Input: `{ source_url?, title?, transcript, audio_url? }`  
- Bước: sanitize, save `sources/lessons`, **split sentences** (rule-based: `.?!` + viết tắt), bulk insert.  
- Output: `lesson_id`.

#### 2.2 `generate-exercises`
- Input: `{ lesson_id, options: { listeningCloze: { default='2-3', blanksPerSentence='auto' }, readingCloze: { density='medium' } } }`
- Tạo:
  - **reading_cloze**: từ transcript → ẩn **content words** (noun/verb/adj/adv), tránh stopwords; density theo cài đặt.
  - **listening_cloze**: mặc định **2–3 từ** (chọn cụm liền nhau), ưu tiên **chunks đã chọn** nếu có.
  - **speaking**: lấy danh sách câu quan trọng (từ chunks hoặc manual pick).
  - **writing**: tạo prompts tiếng Việt từ nội dung bài (rule-based templates).
- Output: danh sách exercises → upsert `exercises`.

#### 2.3 `submit-result`
- Ghi điểm cho người dùng: `{ user_id, lesson_id, kind, result }` → cập nhật `user_progress.score`.

#### 2.4 `srs-schedule`
- Áp dụng **SM-2** đơn giản: quality 0–5 → cập nhật `interval_days, ease, reps, lapses, due_at`.

**Mục tiêu chấp nhận**
- Gọi được functions, sinh ra exercises hợp lệ cho 1 bài mẫu.

---

### M3 — Nhập liệu (UI Importer) (1–1.5 ngày)
- Trang **/importer**:
  1) Paste **URL**, **title**, **transcript**, **audio URL** hoặc **Upload**.  
  2) Preview transcript → **Split sentences** (cho phép sửa tay).  
  3) Lưu → tạo `lesson`.  
- Hiển thị “**Legal note**”: chỉ dùng cho mục đích học cá nhân.

**Mục tiêu chấp nhận**
- Nhập thành công 1 bài, tách câu chuẩn, xem lại được ở /lesson/:id.

---

### M4 — Reading + Gợi ý chunks (2–3 ngày)

#### 4.1 Viewer Reading
- Transcript + **Glossary Panel** bên phải (desktop) / bottom sheet (mobile).  
- Nút **“Gợi ý chunks”**.

#### 4.2 Thuật toán gợi ý (MVP không LLM)
- **Tokenize** + POS tagging nhẹ (regex/wordlist).  
- Bóc tách:
  - **Collocation patterns**: *verb+noun* (take a look), *adj+noun* (fast learner), *verb+prep* (depend on),  
  - **Phrasal verbs**: look up, wind down, put off (wordlist).  
  - **Useful patterns**: *be used to*, *make sure*, *as soon as*, *in case*.  
- Tính **điểm ưu tiên**: tần suất, độ “có ích” (list cứng), độ dài, nằm trong câu “key”.  
- UI cho phép **tick chọn** → tạo `chunks` + đề xuất **ví dụ** (trích câu thật).

**Mục tiêu chấp nhận**
- Chọn ít nhất 8–12 chunks cho 1 bài; thêm vào **SRS** thành công.

---

### M5 — Listening Cloze (2–3 ngày)

#### 5.1 Generator
- Default **2–3 từ** mỗi chỗ trống.  
- Tránh ẩn **stopwords**, ưu tiên ẩn cụm **chunks**.  
- Tuỳ chọn: 1 từ / cả câu / cả bài.

#### 5.2 Player
- Audio player (seek, tốc độ, loop đoạn).  
- Ô điền trống với **tolerance**:
  - Bỏ qua `case`, `punctuation`.  
  - Cho phép lỗi nhỏ: Levenshtein ≤ 1–2 với từ ≤ 6 ký tự.  
- Hints: chữ cái đầu, số ký tự, reveal 1/2 cụm.

**Mục tiêu chấp nhận**
- Làm đúng ≥ 80% testcases đơn giản; ghi điểm vào `user_progress`.

---

### M6 — Speaking (2 ngày)

#### 6.1 Flow
- Danh sách câu “quan trọng” → **Record** từng câu.  
- **ASR**: Web Speech API (en-US) → transcript.  
- So khớp:  
  - Normalize: lowercase, bỏ punctuation, contractions mapping (I’m → I am).  
  - **WER** (word error rate) & **coverage** chunk: highlight *missing/mispronounced* (dựa text).  
- Phản hồi: badge “Great / Good / Try again”; cho phép **re-record**.

**Mục tiêu chấp nhận**
- Trải nghiệm ổn trên Chrome/Edge; graceful fallback khi browser không hỗ trợ.

---

### M7 — Writing (2 ngày)

#### 7.1 Flow
- App đưa **prompt tiếng Việt “đời thường”** từ bài → user trả lời **bằng tiếng Anh**.  
- **Rule-based feedback**:
  - Kiểm tra **coverage** của **chunks** (đã học) trong câu trả lời.  
  - Mẫu lỗi cơ bản: thiếu `a/an`, `plural -s`, `preposition` thông dụng, `article` trước danh từ đếm được.  
  - Gợi ý **native-like rewrite** bằng **patterns** đã lưu (ví dụ: *wind down*, *grab a coffee*, *make sure to*).  
- **Hỏi lại bằng tiếng Anh**: user trả lời lại với câu đã sửa.

**Mục tiêu chấp nhận**
- UI hiển thị diff highlight; lưu lịch sử 2–3 lần sửa gần nhất.

---

### M8 — Ôn tập nhẹ cuối bài (1–1.5 ngày)
- Random từ **chunks đã chọn**:  
  - **Reading**: cloze chọn từ đúng (1 lựa chọn đúng + 3 distractors).  
  - **Listening**: điền 1–3 từ từ audio cũ.  
  - **Speaking**: đọc lại 1–2 câu.  
  - **Writing**: hỏi lại 1 prompt EN, yêu cầu dùng ≥1 chunk.
- **Đánh dấu xong bài** → cập nhật `user_progress.status='completed'`.

**Mục tiêu chấp nhận**
- Một vòng ôn tập hoàn chỉnh ≤ 5 phút.

---

### M9 — Kho bài & Mini/Big Test (1–2 ngày)
- **/library**: filter theo tag/level; “Đã học”.  
- **Chọn nhiều bài** → tạo **test**:
  - Tập hợp **chunks** + **exercises** liên quan.  
  - Thời lượng mini (≈10 phút) / big (≈25 phút).
- Lưu **kết quả test** (tổng quan + kỹ năng).

**Mục tiêu chấp nhận**
- Tạo/chạy test ổn định, có summary điểm.

---

### M10 — Mobile polish, PWA & Analytics (1–1.5 ngày)
- Bottom Nav, cỡ chữ, khoảng chạm lớn.  
- PWA (offline shell + cache audio optional).  
- Sự kiện analytics: `lesson_open`, `chunk_add`, `cloze_submit`, `speak_score`, `write_feedback`, `review_done`, `test_finish`.

**Mục tiêu chấp nhận**
- Lighthouse PWA pass cơ bản, TTI tốt trên mobile.

---

## 4) Data Contracts (Zod/TS)

```ts
// Cloze blank
export type Blank = {
  start: number; // index trong câu
  end: number;
  answer: string; // "wind down" hoặc 1-3 từ
  hint?: { firstLetter?: boolean; length?: number };
};

export type ExerciseReadingCloze = {
  type: 'reading_cloze';
  sentenceId: string;
  text: string;           // câu gốc
  blanks: Blank[];
  choices?: string[];     // distractors
};

export type ExerciseListeningCloze = {
  type: 'listening_cloze';
  sentenceId?: string;    // optional nếu theo đoạn/bài
  scope: 'phrase' | 'sentence' | 'paragraph' | 'full';
  blanks: Blank[];
  audioUrl: string;
  startSec?: number;
  endSec?: number;
};

export type ExerciseSpeaking = {
  type: 'speaking';
  sentenceIds: string[];
};

export type ExerciseWriting = {
  type: 'writing';
  promptVi: string;
  targetChunks: string[]; // yêu cầu sử dụng
};
```

---

## 5) Thuật toán & tiêu chí

### 5.1 Chunk Suggestion
- **Rule sets**:
  - Phrasal verbs (wordlist ~500 mục).
  - Collocations templates: `(verb + noun)`, `(adj + noun)`, `(verb + prep)`.
  - Patterns hữu ích: *be used to, make sure (to), end up (V-ing), as soon as, in case*…
- **Ưu tiên**: xuất hiện ≥2 lần, cụm 2–3 từ, có tính chuyển dụng cao trong đời sống.
- **UX**: tick chọn → thêm vào SRS + gợi ý ví dụ.

### 5.2 Listening Cloze
- **Default 2–3 từ**: lấy cụm liền nhau; tránh dính punctuation; không chọn stopwords thuần.  
- **Scoring**: normalize → token-level compare; cho Levenshtein ≤ 1–2/word (ngắn).

### 5.3 Speaking
- **ASR** → chuẩn hóa contractions, số nhiều, `to/be` rơi.  
- **WER** + **chunk coverage** ≥ 70% → “Pass”; < 70% → “Try again” + highlight.

### 5.4 Writing
- **Checks**:  
  - Has at least **1–2 target chunks**.  
  - Lỗi cơ bản: article, plural, preposition hay gặp.  
- **Feedback**: đưa **rewrite** theo pattern/chunk; hiển thị diff.

### 5.5 SRS (SM-2 rút gọn)
```
if q < 3:
  reps=0; interval=1; ease=max(1.3, ease-0.2)
else:
  reps+=1
  if reps==1: interval=1
  else if reps==2: interval=6
  else: interval=round(interval*ease)
  ease = ease + (0.1 - (5-q)*(0.08 + (5-q)*0.02))
due_at = now + interval days
```

---

## 6) Giao diện & thành phần (shadcn/ui)

- **Shell**: Header, **BottomNav** (mobile), ThemeToggle.  
- **Importer**: Textarea transcript, input URL, input audio, preview sentences.  
- **Lesson View**:  
  - Tabs: **Reading / Listening / Speaking / Writing / Review**  
  - Reading: Transcript, **GlossaryPanel**, “Gợi ý chunks”, tick-to-SRS.  
  - Listening: Player, Cloze form, Hints, Submit.  
  - Speaking: Card từng câu, Record/Stop, Score.  
  - Writing: Prompt (VI), Editor (EN), FeedbackDiff.  
  - Review: 4 mini-drills xen kẽ.  
- **Library**: LessonCard (đã học/chưa học), filter.  
- **Tests**: Builder (select multiple lessons) → Test Runner.

---

## 7) Kiểm thử

- **Unit**: tokenization, cloze generator, similarity, SM-2.  
- **Component**: Reading viewer, Cloze, Record button.  
- **E2E (Playwright)**:  
  1) Import bài → Reading chọn 10 chunks → Listening cloze (2–3 từ) → Speaking 3 câu → Writing 1 prompt → Review → Mark completed.  
  2) Chọn 3 bài → tạo Mini Test → làm xong → xem summary.

---

## 8) Bảo mật & pháp lý (MVP)

- **is_private = true** cho mọi lesson import; lưu `source_url`.  
- Không “xuất bản” transcript/audio ra public; chỉ dùng trong phiên học của tài khoản đó.  
- Rate-limit `import-from-manual`; log hoạt động import.

---

## 9) DevOps & cấu hình

- **ENV Frontend**:  
  - `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`.  
- **ENV Functions** (server):  
  - `SERVICE_ROLE_KEY` (chỉ chạy trên Edge Functions).  
- **CI**: build, test; Vercel preview; Supabase migration automation.  
- **PWA**: vite-plugin-pwa (cache manifest, offline shell; audio optional).

---

## 10) Timeline đề xuất (≈ 10–12 ngày công)

- **M0**: Bootstrap — 0.5–1d  
- **M1**: Schema + RLS — 1–1.5d  
- **M2**: Edge functions — 2–3d  
- **M3**: Importer UI — 1–1.5d  
- **M4**: Reading + chunks — 2–3d  
- **M5**: Listening — 2–3d  
- **M6**: Speaking — 2d  
- **M7**: Writing — 2d  
- **M8**: Review + Test — 1–2d  
- **M10**: Polish + Analytics — 1–1.5d  
> (Một số hạng mục sẽ chạy song song; tổng thể ~2 tuần lịch.)

---

## 11) Tiêu chí hoàn thành (DoD) cho MVP

- Nhập 1 bài từ DailyDictation **thủ công** → tạo được lesson + sentences.  
- Chọn ≥ 8 chunks → thêm vào **SRS**.  
- Listening Cloze **mặc định 2–3 từ** hoạt động ổn (tolerance chính tả nhẹ).  
- Speaking chấm bằng **ASR** + WER; feedback realtime.  
- Writing có **prompt VI → trả lời EN → sửa nhẹ → hỏi lại EN**.  
- Ôn tập nhẹ cuối bài gồm đủ **4 kỹ năng**.  
- Chọn nhiều bài → **Mini/Big Test** chạy được và lưu kết quả.  
- Toàn bộ UI **responsive mobile-first**.

---

## 12) Rủi ro & hướng xử lý

- **ASR không ổn định** → cung cấp transcript gợi ý + nút “I said it”.  
- **Chia câu sai** → cho sửa tay trong Importer.  
- **Khác biệt trình duyệt** Web Speech API → fallback: chỉ ghi âm & self-check (MVP).  
- **Pháp lý** → chỉ học cá nhân; giữ `source_url`; không public; cân nhắc liên hệ chủ sở hữu nội dung nếu muốn phát hành rộng.

---

## 13) Hạng mục tương lai (ngoài MVP)

- Forced alignment (tự động timecode per sentence).  
- Scoring speaking nâng cao (server model).  
- Grammar checker nâng cao (LanguageTool/LLM).  
- Leaderboard, goals, streaks, badges.  
- Subscription (Stripe) & chia sẻ bộ đề.

---

### Checklist trước khi bắt đầu coding
- [ ] Tạo project Supabase + set env.  
- [ ] Chạy migration schema & RLS.  
- [ ] Tạo Edge Functions (stubs) và route key.  
- [ ] Scaffold UI: Shell, Router, BottomNav.  
- [ ] Trang Importer: paste transcript & preview.  
- [ ] Lesson page + Reading tab + Chunk suggest.  
- [ ] Listening Cloze (2–3 từ) + Player.  
- [ ] Speaking (record + ASR + score).  
- [ ] Writing (prompt VI → EN + feedback).  
- [ ] Review cuối bài + Library + Test builder.  
- [ ] Analytics & PWA cơ bản.
