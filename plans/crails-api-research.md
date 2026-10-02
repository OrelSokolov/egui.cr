# Crails — исследование: сколько API Rails переносится 1:1 на Crystal

Дата: 2026-10-02. Источник: клон rails/rails@2a64b2b (8.2) в `~/rails`.
Задача: не копировать внутреннюю магию Rails, а оценить, какую долю
**конечного API, который трогает разработчик**, можно воспроизвести на
Crystal с ощущением «я как будто не уходил с Ruby/Rails». Под капотом —
любая реализация (макросы вместо метапрограммирования).

## Вердикт

**~85–90% ежедневного API Rails — ощущение 1:1 достижимо.**
Ещё ~5% — почти 1:1 с микро-швами. ~2–5% непереносимо в принципе, и это
legacy/edge, которые не нужны новому коду (dynamic finders, `with_options`,
zeitwerk-reload).

Причина, почему цифра такая высокая: подавляющее большинство «магии»
Rails — это **детерминированная кодогенерация на этапе загрузки**
(`define_method`/`class_eval` в builder'ах ассоциаций, enum, роутах,
form builder'е), а не рантайм-`method_missing`. Всё, что генерируется
один раз по статичному описанию, идеально ложится на Crystal-макросы.
Рантайм-`method_missing` в ежедневной поверхности — три с половиной места:
`tag.br`, `respond_to { format.json }`, `atom_feed`, `StringInquirer`.
Всё остальное — boot-time.

## Проверенные механизмы (зонды на Crystal 1.21)

Ключевой факт: в текущем Crystal (1.21) `**opts` есть и в обычных методах,
не только в макросах. Проверено реальными прогонами:

1. `def where(**opts)` → `where(name: "x", age: 18)` работает как обычный
   метод, цепочками, без макросов. Это снимает главный риск по kwargs-DSL.
   Значит `validates :name, presence: true, length: {minimum: 2}`,
   `before_action :auth, only: [:index]`, `resources :posts, only: [...]` —
   синтаксически 1:1.
2. `scope :published do ... end` — макрос со сплайсом тела блока в
   генерируемый def (`{{ block.body }}`). Тело вызывает другие scopes/
   методы класса — работает. Замена `instance_exec`.
3. `{{ run("gen.cr", "users") }}` — compile-time кодогенерация из внешней
   скрипты. Это замена schema-driven `define_method` в AR: скрипт читает
   `schema.yml` (или коннектится к БД) и генерит `def name : String?`,
   `name=`, `name_was`, `name_changed?` для всех колонок. Проверено.
4. Расширение stdlib-типов (`Int#days` → Duration, `Time::Span#ago`) —
   работает, Crystal разрешает добавлять методы в stdlib-типы.
5. Compile-time `descendants`/`constantize`: `{{ @type.all_subclasses }}`
   и macro-case по списку классов — замена `DescendantsTracker`/
   `constantize` для нужд STI/polymorphic.
6. Роут-хелперы: макрос `resources :posts` генерит `posts_path`,
   `edit_post_path(id)` — проверено, имя метода строится из строки.

## Разбор по слоям

### ActiveRecord — ~90% ощущения 1:1

| Группа | 1:1 | Комментарий |
|---|---|---|
| Ассоциации (`belongs_to/has_many/has_one/habtm` + опции) | 90% | Макросы генерят те же имена: `posts`, `posts=`, `build_post`, `create_author!`, `post_ids`. Внутри у Rails `class_eval`-гердоки — но это деталь реализации. Полиморфизм и STI (`becomes`) — через compile-time registry. |
| Валидации | 95% | Практически ноль меты. `validates :x, presence: true, if: ...` — kwargs-метод. `errors.add/full_messages/details` — обычный код. |
| Коллбэки | 95% | `before_save` и 20+ хуков — макросы, регистрирующие символы/блоки в статические списки; порядок исполнения повторить несложно. |
| Скопы | 95% | `scope :name do ... end` — проверено зондом. `default_scope`, `unscoped`, чейнинг — обычный код. |
| Query interface | 90% | `where/order/limit/joins/includes/references/pluck/pick/ids/find_each/in_batches/...` — имена и сигнатуры 1:1 (Relation — иммуттабельные value-объекты, меты нет). `async_*` на fiber'ах — тривиально. Выпадают только dynamic finders `find_by_email_and_age` — legacy, `find_by(email:, age:)` уже их заменил в реальном коде. |
| Persistence + dirty | 90% | `save/update/destroy/touch/increment/insert_all/upsert_all/with_lock` — код. Атрибутные методы (`name`, `name=`, `name_was`, `name_changed?`) — из схемы через `{{ run }}`. |
| Миграции | 95% | DSL — обычные методы (`create_table`, `t.string`, `add_index`, `t.references`, `reversible`). Реверс `change` — command recorder, обычный код. |
| enum / store / delegated_type / nested_attributes | 95% | Всё генератор-макросы: `draft?`, `draft!`, scope `draft` — те же имена через макрос. |

### ActionController + роутинг — ~90%

- `before_action/after_action/around_action/skip_*` + `only:/except:` —
  макросы с `**opts`, синтаксис 1:1.
- `render json:/html:/plain:/status:/layout:`, `redirect_to`, `head`,
  `respond_to` (фикс-методы `format.*` вместо method_missing-коллектора),
  `rescue_from`, `send_data/send_file` — обычный код.
- **Strong params** — `params.require(:post).permit(:title, :body)` —
  обычный класс, ноль меты, порт как есть. `expect` из 8.0 тоже.
- `cookies.signed/encrypted/permanent`, `session`, `flash` (+ `add_flash_types`
  макросом) — код + крипто-shards.
- Роутинг: `resources :posts (only/shallow/concerns/nested/member/collection)`,
  `namespace`, `scope`, `constraints`, `root`, `direct/resolve` — DSL из
  обычных методов; именованные хелперы `*_path/*_url` генерит макрос
  (проверено). Слабое место — polymorphic `url_for([:edit, @post])`-массивы:
  ~70%, основной случай закрывается прямым хелпером.
- `ActionController::Live` (стриминг) — на fiber'ах даже естественнее.

### ActionView хелперы — ~85%

- Текст (`pluralize/truncate/highlight/excerpt/word_wrap/simple_format/cycle`),
  числа (`number_to_currency/...`), даты (`distance_of_time_in_words`),
  `link_to/button_to/mail_to`, `content_tag`, `tag("br")` — всё plain-код.
- Формы: `form_with model: @post do |f| f.text_field :name ... end` —
  FormBuilder со статическим набором методов (в Rails они тоже
  генерятся один раз фиксированным списком). Нейминговые конвенции
  `post[title]`, `_destroy`, `addresses_attributes][0]` — портируются.
- `tag.br` точечная форма — фикс-список ~110 HTML-элементов, сгенерить
  макросом из списка. Ощущение 1:1.
- `content_for/provide`, layouts, partials + `collection` + `#{partial}_counter`
  — поверх ECR (замена ERB согласована).
- **`sanitize`/`strip_tags`** — API 1:1, но нужна HTML-парсер-зависимость
  (аналог Loofah) — это стоимость реализации, не разрыв API.
- `cache do ... end` / Russian doll — MD5-дайджест шаблона считается
  статически по исходнику — переносимо.

### ActiveSupport — ~85%

- **core_ext, ежедневный набор**: `blank?/present?/presence/in?/deep_dup`,
  String (`squish/truncate/at/from/first/last/starts_with?/indent` + весь
  Inflector), Hash (`symbolize_keys/deep_merge/except/slice/reverse_merge/
  compact_blank`), Array (`in_groups_of/split/to_sentence/second.../wrap`),
  Enumerable (`index_by/index_with/many?/pluck/sole/in_order_of`), Duration
  (`5.days/2.hours.ago`, `1.month.ago` календарно), вся дата-математика
  (`beginning_of_day/all_day/next_week/...` + `Time.zone`/`TimeWithZone`
  поверх `Time::Location`), `NumberHelper`, UUID, `SecureRandom.base58`.
  Всё — чистая логика + добавление методов в stdlib-типы. 1:1.
- `Concern` (`included do/class_methods do`), `delegate :name, to: :user`,
  `mattr_accessor`, `class_attribute`, `thread_mattr_*` — макросы
  (Crystal `included`-хук есть). 1:1 по ощущению.
- `Notifications.instrument/subscribe`, `Rails.cache.fetch/read/write`
  (+ race_condition_ttl), `I18n.t` с yml-локалями и плюрализацией,
  `MessageVerifier/MessageEncryptor`, `CurrentAttributes` (на fiber-locals),
  `Deprecation`, `TaggedLogging`, `ErrorReporter` — обычный код. 1:1.
- `HashWithIndifferentAccess` — аппроксимация: params-объект с
  перегрузкой `[](Symbol|String)`. Для `params` ощущение сохраняется;
  как общий тип — микро-шов.

## Что не переносится в принципе (честный хвост ~2–5%)

1. **Dynamic finders** `find_by_email!` — рантайм-`method_missing` → кэш
   методов. В живом коде 3–8 заменены на `find_by(email:)`, который 1:1.
2. **`constantize` по рантайм-строке** — только compile-time вариант или
   ручной registry. Нужен редко (фабрики, STI-строки — закрывается
   `{{ @type.all_subclasses }}`).
3. **`String.inquiry.production?`** — заменяется enum/макросом:
   `Rails.env.production?` будет работать, но это другой механизм.
4. **`with_options`** — держится на `method_missing`. Малопопулярен,
   выкидываем.
5. **Zeitwerk/autoload/dev-reload** — компилируемый язык; reload = rebuild
   (bin/watch). `LazyLoadHooks/on_load` — выполнить при старте.
6. **`instance_eval`/`send`/monkeypatch-переопределения** существующих
   методов — в Crystal нельзя переопределять, только добавлять. AS почти
   везде добавляет, не переопределяет — конфликтов минимум, но чужие
   гемы, переопределяющие ядро, не портируются (нас не касается).
7. `eval`-полигон `Rails.application.routes.draw` со строками — сам DSL
   портируем, но любые строковые `controller "foo"`-трюки — компилтайм.
8. Тестовые хелперы AS (`travel_to`, `assert_difference`) — портируются
   позже, не блокер.

## Соответствие эпох Rails 3–8

Ядро (AR-DSL, коллбэки, скопы, миграции, контроллеры, хелперы текста/
чисел/форм) стабильно с 3.0 по 8.2 практически без ломающих изменений.
Таргетироваться на 8.2 API: приложения 4.2–8.x переносятся почти
дословно; эра 3.x отличается `attr_accessible` и `form_for` — опционально
добавить совместимый слой.

## Существующие наработки в Crystal (не с нуля)

- **jennifer.cr** — AR-подобный ORM: query interface, ассоциации, миграции
  во многом уже реализованы (синтаксис чуть другой — можно форкнуть/обучить).
- granite-orm — ассоциации/валидации макросами (доказательство паттерна).
- avram (Lucky) — форма-билдеры и валидации макросами.
- i18n-шарды, crypto-shards — есть.

## Названия гемов

Шарды `activerecord`, `activesupport`, `actionpack`, `actionview`,
`railties` → `crails` как метапакет. Топ-левел неймспейсы те же:
`ActiveRecord::Base`, `ActiveSupport::Concern` — в Crystal легально.

## Расширение матрицы: остальные гемы (ActionCable, ActiveStorage,
## ActiveJob, ActionMailer, ActionMailbox, ActionText, Railties)

### ActionCable — ~90%

- DSL: `stream_from/stream_for/stop_all_streams/transmit/reject`,
  `CommentsChannel.broadcast_to(@post, msg)`, `identified_by :current_user`,
  `connect/disconnect`, `periodically :tick, every: 5.seconds`,
  `before_subscribe/after_subscribe` — макросы + обычный код. 1:1.
- Протокол: обычный WebSocket на `/cable` с JSON-конвертами
  (`command/welcome/subscription_confirmation/ping/disconnect`) —
  переносим as-is, JS-клиент не трогаем вообще.
- Runtime-модель: у Ruby nio4r event loop + thread pool; в Crystal
  fiber-per-connection поверх `HTTP::WebSocket` (stdlib) — ложится
  естественнее, чем в Ruby. Pubsub-адаптеры (PG LISTEN/NOTIFY, Redis) —
  обычный код.
- Единственный шов: «публичный метод канала = RPC-экшен» держится на
  рантайм `public_send` по строке от клиента. В Crystal — макрос-таблица
  диспетчеризации (или аннотация `@[CableAction]`). Ощущение для
  разработчика сохраняем: пишешь `def speak(data)` — работает.

### ActiveStorage — ~85%

- `has_one_attached :avatar` / `has_many_attached` (+ блок с именованными
  вариантами `attachable.variant :thumb, resize_to_limit: [100, 100]`) —
  внутри `class_eval`-гердоки → Crystal-макрос 1:1. Генерятся те же имена:
  `avatar`, `avatar=`, `with_attached_avatar`.
- `attach(io:, filename:, content_type:)`, `attached?`, `purge(_later)`,
  `variant(...)`, `preview`, `representation`, `url`, `download`, `open`,
  `blob.filename/byte_size/checksum/content_type`, `Blob.find_signed!` —
  портируются. Утиная типизация attachable (7 форм) → union/оверлоады,
  compile-time даже честнее.
- Сервисы Disk/S3/GCS/Mirror — HTTP/FS-код, portable. Direct upload
  (presigned URL) — portable. Фоновые Analyze/Purge — ActiveJob.
- Затраты (не разрыв API): обработка картинок — нужен libvips/ImageMagick
  биндинг или шелл-аут; превью PDF/видео — ffmpeg/poppler, как у Rails.
- Ambient `ActiveStorage::Current` (хост для URL) — fiber-local.

### ActiveJob — ~90%

- `queue_as :default`, `retry_on(Error, wait: 3.seconds, attempts: 5,
  jitter:)`, `discard_on`, `after_discard`, коллбэки
  `before/after/around_perform(_enqueue)`, `set(queue:, wait:, wait_until:)`,
  `perform_later/perform_now`, `perform_all_later` (bulk) — всё либо код,
  либо макросы. 1:1.
- `async`-адаптер по умолчанию — fiber'ы; retry-математика
  (polynomial backoff) — статика. Continuable jobs (8.2, `step`) —
  книжкепинг в сериализованном payload, portable.
- Шов: десериализация джоба делает `safe_constantize(job_class)` по строке
  → compile-time registry `{{ all_subclasses }}` (список джобов известен
  на компиляции). GlobalID (`gid://app/User/1`, `to_sgid(expires_in:)`) —
  тот же registry; локацию модели в пределах одного приложения закрывает
  таблица AR-классов.

### ActionMailer — ~80%

- DSL: `default from:`, `layout "mailer"`, `def welcome_email(user) ...
  mail(to:, subject:)`, `attachments[...]`/`attachments.inline`,
  `.with(user: u).welcome`, `.deliver_later(wait: 5.minutes)`,
  multipart auto-discovery (`welcome_email.{html,text}.ecr`), i18n-subject,
  `before_action/after_deliver`, observers/interceptors — макросы + код.
- Швы: `UserMailer.welcome_email(user)` в Rails — классовый
  `method_missing` → MessageDelivery; в Crystal макрос генерит
  классовый метод на каждый экшен (ощущение то же). `deliver_later`
  сериализует имя класса мейлера → registry, как в ActiveJob.
- **Главная скрытая поверхность: порт mail-гема** (MIME-сборка, SMTP,
  sendmail, file). Это самая большая чистая работа среди всех гемов, но
  это library, не DSL.

### ActionMailbox — ~85% (крошечный)

`routing address => :mailbox` (+ String/Regexp/Proc/:all), `def process`,
`bounce_with`, ingress-контроллеры (relay/postmark/sendgrid/mailgun),
`InboundEmail` с enum статусов и incinerate-джобой. Шов: `constantize`
имени mailbox по строке — compile-time registry. Depends on
Mailer/Storage/Job.

### ActionText — ~75-80%

- `has_rich_text :body` — прямой аналог макросом (внутри и в Rails
  `class_eval`). `RichText#to_s/to_plain_text/to_markdown`,
  `content.html`, `to_editor_html`, кастомный партиал
  `app/views/action_text/contents/_content`.
- SGID-резолвция аттачей в рантайме → registry разрешённых классов.
- HTML-фрагментные трансформации (Nokogiri/Loofah) → нужен HTML-парсер
  на Crystal (есть кристаллические варианты, или lexbor-биндинг).
  Trix-редактор — клиентский JS, работает как есть.

### Railties / CLI — ~75-80%

- `rails new/generate/model/controller/scaffold/migration/mailer/job/
  channel/mailbox`, `console/server/routes/runner/db:*/credentials:*/
  encrypted:*/about/initializers/middleware` — отдельный CLI-инструмент
  (в компилируемом языке логичнее внешний `crails` бинарник, не вшитый
  в приложение). Генераторы = Thor-классы → Crystal-CLI + свои шаблоны.
- `Rails.application/routes/env/root/logger/cache/credentials`,
  `config.x.*`, `config.load_defaults`, `initializer "name" do`,
  `to_prepare`, middleware-стек `use/insert_before/insert_after/swap/
  delete` — стек переносится на `HTTP::Handler`-цепочку с теми же
  операциями. Конфиг: типизированный конфиг-объект вместо
  OrderedOptions-method_missing (`config.action_mailer.foo = ` —
  работает, но с фиксированным набором полей; произвольные ключи через
  `config.x` как Hash).
- `Rails.env.production?` — enum с предикатами, ощущение 1:1.
- Выпадает: dev-reload/Zeitwerk/`to_prepare` (→ rebuild/restart),
  `Rails.application.secrets` (удалён и в 8.x, есть credentials).

### Полная матрица по фреймворку

| Компонент | Ощущение 1:1 | Комментарий |
|---|---|---|
| ActiveRecord | ~90% | ядро фреймворка, почти всё макросами |
| ActionPack (контроллеры+роутинг) | ~90% | |
| ActionView (хэлперы) | ~85% | sanitize = нужен HTML-парсер |
| ActiveSupport | ~85% | |
| ActionCable | ~90% | на fiber'ах естественнее, чем на Ruby |
| ActiveJob | ~90% | constantize → registry |
| ActiveStorage | ~85% | vips/ffmpeg — стоимость, не API |
| ActionMailer | ~80% | порт mail-гема — самая большая работа |
| ActionMailbox | ~85% | крошечный |
| ActionText | ~75% | HTML-мунгинг + registry sgid |
| Railties/CLI | ~75% | генераторы/команды — внешний CLI |

**Итог по всему фреймворку: взвешенно по реальному использованию —
те же ~85%.** Разница между «ядром» и «полным фаршем» — плюс-минус
5%, потому что добавляющиеся гемы либо крошечные обёртки (Mailbox),
либо macro-friendly (Cable, Job, Storage), а главные скрытые работы —
mail-gem и HTML-парсер — это library-строительство, не разрывы DSL.

## MVP-порядок (если делать)

1. `activerecord` shard: `{{ run }}`-кодоген из schema.yml → атрибуты;
   Relation (where/order/limit/joins/includes/pluck/find_each);
   валидации + коллбэки + ассоциации belongs_to/has_many/has_one;
   миграции DSL (PostgreSQL). Это ядро, покрывающее ~80% Daily-использования.
2. `actionpack`: роутер (resources DSL + макрос-хелперы), контроллеры
   (before_action, render, params.require/permit, cookies/session/flash).
3. `actionview`: ECR-интеграция, form builder, text/number/url-хелперы.
4. `activesupport`: blank/present, Duration/даты, Inflector, Concern,
   delegate, Notifications, Cache (memory+file), I18n.
5. `actioncable`: fiber-коннекты + канал-макросы (дешёвый выигрыш на
   Crystal-стеке).
6. `activejob`: fiber-pool адаптер + retry/discard DSL + registry.
7. Хвост: ActiveStorage (vips), ActionMailer (порт mail), санитайзер,
   STI/becomes, enum-экзотика, Live-стриминг.
