# أدوات موصل يقين v1 (قراءة فقط)

## ما ينطبق على كل الأدوات

**الحماية:**
- `readOnlyHint: true`.
- مخطط مدخلات مغلق (`additionalProperties: false`).
- لا يوجد أي مُدخل للشركة أو المستخدم أو الدور.

**قبل كل أداة:**
1. التحقق من الرمز عبر GoTrue.
2. `mcp_begin`: حد 30 طلباً في الدقيقة و600 في اليوم، وسجل الاستخدام.
3. `mcp_guard()`: يتحقق أن الجلسة قائمة، والحساب مفعّل، والمستخدم ليس مسؤول منصة، وخطاف الحماية مثبت.

**المخرجات:** JSON فيه:
- `as_of`
- `notes_ar` (ملاحظات عن حدود البيانات)
- `total` و `limit` و `offset` في القوائم

**النطاق:** الشركة = `my_company()`، والقسم = RLS. الموظف يرى قسمه فقط، والمدير يرى الشركة.

## الأدوات

| أداة MCP | دالة SQL | المدخلات (النوع، الحدود) | مصدر البيانات (جداول ودوال موجودة) | المخرجات | الحدود والصفحات |
|---|---|---|---|---|---|
| `yaqen_company_overview` | `mcp_company_overview()` | لا شيء | `dashboard_stats`، `company_alerts`، companies | اسم الشركة، النطاق، أرقام اللوحة، التنبيهات حسب النوع، عدد العاجلة | تنبيهات حتى 500 |
| `yaqen_projects` | `mcp_projects` | status (enum من 4 قيم)، late_only (bool)، limit (1-50)، offset (0-100000) | projects | ملخص (العدد، متوسط الإنجاز، مجموع العقود، **عدد الناقص** من القيمة والتاريخ) + قائمة بأيام التأخير | 50 لكل صفحة، ترتيب ثابت (التأخير، التاريخ، المعرّف) |
| `yaqen_project_detail` | `mcp_project_detail` | project_id (uuid، إلزامي) | projects، departments | المشروع، والملاحظات في `untrusted_text` (مقصوصة لـ 500 حرف)، وقائمة **غير المتاح** | سجل واحد. لمشروع خارج الصلاحية: `found: false` |
| `yaqen_invoices` | `mcp_invoices` | kind (صادرة/واردة)، status (enum)، min_days_overdue (0-3650)، limit، offset | invoices | ملخص: المجموع، غير المدفوع، **التقادم 4 شرائح**، الناقص من تاريخ الاستحقاق + قائمة بأيام التأخير | 50 لكل صفحة |
| `yaqen_fleet` | `mcp_fleet` | status (enum)، location (نص ≤ 80)، limit، offset | vehicles | تجميع حسب الموقع والحالة + قائمة بتواريخ الانتهاء | 50 لكل صفحة |
| `yaqen_expiring` | `mcp_expiring` | days (1-365) | `company_alerts` (الأنواع expiry و hearing) | العناصر مع الأيام المتبقية (السالب = منتهٍ) | حتى 500 |
| `yaqen_people` | `mcp_people` | department (نص ≤ 80)، limit، offset | profiles، departments | عدد حسب القسم + الاسم والمسمى والقسم وهل هو مدير. **بدون جوال ولا بريد** | 50 لكل صفحة، النشطون فقط |
| `yaqen_search` | `mcp_search` | query (2-80، إلزامي)، limit (1-20) | projects، vehicles، invoices، documents، profiles | نتائج لكل نوع | 20 لكل نوع. رموز `%` و `_` و `\` تُزال |
| `yaqen_notes_rooms` | `mcp_notes_rooms` | limit | manager_notes، rooms، room_messages (عدد فقط) | الملاحظات المفتوحة، والغرف بعدد الرسائل وآخر نشاط | 50 |
| `yaqen_invoice_period_comparison` | `mcp_profit_comparison`، ويستدعي `report_profit_comparison` | 4 تواريخ (YYYY-MM-DD، إلزامية، والفترة ≤ 366 يوماً) | invoices، departments | الصادرة والواردة وصافي الفوترة والمحصّل وغير المحصّل لكل فترة، والتغير المطلق والنسبة (null عند قاعدة صفرية)، وأكبر 5 عملاء، وحسب القسم، والمستبعد لعدم وجود تاريخ استحقاق، و`net_profit.available = false` مع الأسباب | — |

## رموز الأخطاء (تصل للنموذج بدون أي تفاصيل من قاعدة البيانات)

| الرمز | المعنى |
|---|---|
| `SESSION_REVOKED` | لا يوجد session_id، أو الجلسة محذوفة أو منتهية أو لمستخدم آخر |
| `ACCOUNT_INACTIVE` | الحساب معلّق أو موقوف أو بلا شركة |
| `PLATFORM_ADMIN_NOT_SUPPORTED` | مسؤول المنصة غير مدعوم في v1 |
| `CONFIG_INCOMPLETE` | خطاف الحماية غير مثبت، فالأدوات ترفض العمل |
| `RATE_LIMITED_MINUTE` / `RATE_LIMITED_DAY` | تجاوز حد الطلبات |
| `INVALID_ARGUMENT` / `INVALID_PERIOD` / `QUERY_TOO_SHORT` | مدخلات غير صحيحة |
| `TIMEOUT` | انتهت المهلة (8 ثوانٍ في قاعدة البيانات، و10 في الخادم) |
| `UPSTREAM_UNAVAILABLE` | أي خطأ آخر (يُسجَّل في system_events بدون الرمز والمدخلات) |

مدخلات غير صحيحة النوع أو أداة غير موجودة: JSON-RPC `-32602` قبل الوصول لقاعدة البيانات.

## أمثلة أسئلة المدير وما يُستدعى

| السؤال | الأداة |
|---|---|
| أعطني ملخص وضع الشركة اليوم | `yaqen_company_overview` |
| ما المشاريع المتأخرة؟ | `yaqen_projects {late_only: true}` |
| ما المعدات المتوقفة في كل موقع؟ | `yaqen_fleet {status: "متوقفة"}` (قراءة `by_location`) |
| ما الفواتير التي تجاوزت 30 يوماً؟ | `yaqen_invoices {min_days_overdue: 30}` |
| ما الوثائق التي ستنتهي خلال الشهر؟ | `yaqen_expiring {days: 30}` |
| أعطني ملخصاً عن مشروع الجافورة | `yaqen_search {query: "الجافورة"}` ثم `yaqen_project_detail` |
| قارن نوفمبر بأكتوبر | `yaqen_invoice_period_comparison` (والنموذج مُلزم بذكر أن صافي الربح غير متاح) |
