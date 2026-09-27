--- Отказы: до человека доходит только то, что ему поможет, остальное —
--- в журнал.
---
--- Сегодня каждый пакет возвращает свою пару `nil, err`, и во что она
--- превратится на экране, решает тот, кто ближе к HTTP. Отсюда два
--- одинаково плохих исхода: либо наружу уезжает текст внутреннего отказа
--- со стеком и путями, либо человек видит «внутренняя ошибка» там, где ему
--- хватило бы одной внятной строки.
---
--- Весь пакет держится на одном различии.
---
--- **Ожидаемый отказ** — тот, про который знали заранее: нет такого
--- клиента, пароль не подходит, поле не заполнено, сервер занят. У него
--- есть код, строка для человека и подходящий статус ответа. Он идёт
--- наружу целиком.
---
--- **Внутренняя поломка** — обращение к пустоте, отказ чужой библиотеки,
--- порванное соединение с базой. Наружу от неё уходит ровно одно:
--- опознаватель происшествия и общая фраза. Подробности — в журнал,
--- где их найдут по тому же опознавателю.
---
--- Отсюда правило, которому подчиняется весь пакет: показывается только
--- то, что написал разработчик — строка из каталога или строка обёртки.
--- Текст, про который неизвестно, кто его сочинил, наружу не выходит
--- никогда, даже если он безобиден.
---
--- И второе правило, из первого не следующее: пакет не угадывает. Что
--- ему передали — код отказа или слово для человека — сказано вызовом
--- (`wrap` против `explain`), а не выведено из вида строки. Догадка
--- стоила дорого: чужое `timeout` — латиница, без пробелов — принималось
--- за код, не находилось в каталоге и роняло узел вместо того, чтобы
--- ответить внятным словом.
---
--- Пользоваться так:
---
---     local errors = require('tnt.error')
---
---     errors.define('customer.not_found', { status = 404, message = 'Клиента №{id} нет' })
---
---     local customer = storage.get(id)
---     if customer == nil then
---         return nil, errors.new('customer.not_found', { id = id })
---     end
---
---     -- выше по стеку
---     local shown, err = errors.guard(handle, request)
---     if err ~= nil then
---         return errors.response(err)      -- статус, заголовки и тело
---     end
---
--- Опознаватель происшествия читается вслух по телефону: `4KJ7-QW9M`,
--- а не UUID на тридцать шесть знаков. Он попадает и в ответ, и в запись
--- журнала — и это единственное, что их связывает.
---
--- Ответ об отказе бывает двух видов, и выбирает между ними сам запрос.
--- Сценарию уходит тело по договору — RFC 9457 либо простой вид, — а
--- браузеру, попросившему `text/html` заголовком `Accept`, страница
--- (`tnt.error.accept`, `tnt.error.page`): в бою с номером происшествия,
--- а по настройке `debug` внутренней поломке — страница разбора с местом
--- в коде, цепочкой отказа, запросом и его заголовками. Тайны вырезаны
--- и оттуда — тем же правилом, что из записи журнала.
---
--- Слово отказа говорит на языке запроса, если каталогу дали перевод —
--- настройку `translate` (`tnt.error.translation`): функцию от отказа
--- и запроса, которая отдаёт слово по коду и подстановкам. Переводчика
--- пакет не знает, связывает их тот, кто собирает приложение.
---
--- Пять решений, о которых стоит знать заранее.
---
--- Отказ соседнего пакета не считается поломкой. Договор границы HTTP
--- простой: таблица с числовым `status` (4xx либо 5xx) и необязательными
--- `message`, `code`, `incident`, `headers`. Такую таблицу пакет узнаёт
--- по числу в `status` — не по виду строки, догадок в нём нет нигде, —
--- сохраняет её статус и заголовки, не выдаёт второго опознавателя
--- и не пишет о ней «внутренняя поломка»: о происшествии уже написал
--- тот, кто отказал. Без этого 404 роутера превращался в 500.
---
--- Фабрика называется `registry`, а не `new`: имя `new` занято заведением
--- отказа. Так его называет договор пакета, и портить главный вызов ради
--- единообразия со второстепенным не стоит.
---
--- Опознаватель выдаётся ровно тогда, когда о происшествии написано
--- в журнал. Иначе он ведёт в никуда: человек называет номер, а дежурный
--- не находит по нему ничего.
---
--- `configure` меняет настройки общего каталога, но не заводит новый.
--- Отказы объявляются пакетами при загрузке, то есть до всякой настройки,
--- и новый каталог потерял бы их все.
---
--- Слово чужого объявления заменяется `redefine`, а не вторым `define`:
--- занятый код `define` по-прежнему не отдаёт. Приложение, которому
--- не годится слово пакета — например общая фраза при 500, — говорит
--- о замене вслух, и тогда она законна. Опознаватель происшествия
--- в этом слове обязан остаться: он и есть весь ответ при 500.

local json = require('json')

local accept = require('tnt.error.accept')
local catalog = require('tnt.error.catalog')
local failure = require('tnt.error.failure')
local hook = require('tnt.error.hook')
local incident = require('tnt.error.incident')
local options = require('tnt.error.options')
local page = require('tnt.error.page')
local render = require('tnt.error.render')
local secret = require('tnt.error.secret')
local translation = require('tnt.error.translation')
local web = require('tnt.error.web')

local log = require('tnt.log').new('tnt.error')

local Module = {}

--- Код внутренней поломки. Объявлен в каждом каталоге с самого начала:
--- без него нечем ответить на первую же панику. Само объявление и правило
--- про `{incident}` в его слове живут у каталога: он открыт полем реестра,
--- и проверка, стоящая только здесь, обходилась бы обращением напрямую.
Module.INTERNAL = catalog.INTERNAL

--- Код чужого отказа, который своего кода не назвал.
---
--- Объявлять его в каталоге незачем: ни статуса, ни слова каталог
--- за чужой отказ не выбирает — и то и другое приезжает с ним самим.
--- Код нужен только затем, чтобы у рода отказа был URI, а у простого
--- вида — поле `error`.
Module.REFUSED = 'refused'

--- Слово чужого отказа, который своего слова не сказал.
---
--- Общее и без подробностей: что именно не так, знает отказавший, и если
--- он смолчал, выдумывать за него нечего.
local REFUSED_MESSAGE = 'Запрос отклонён'

--- Что сказать, когда накрыть причину просят кодом, которого нет.
---
--- Причина называется в тексте исключения: до `of` дело не дойдёт, записи
--- о происшествии не будет, и без этой строки причина пропала бы
--- бесследно — остался бы один опечатанный код.
local UNKNOWN_CODE = 'отказ %s не объявлен: объявите его define '
    .. 'либо накройте причину словом через explain (причина: %s)'

--- С какого статуса отказ перестаёт быть ожидаемым.
---
--- 4xx — «так бывает»: клиент ошибся адресом, способом или телом запроса.
--- 5xx — «так быть не должно», и тем, кто спрашивает `expected`, важна
--- именно эта разница, а не то, кто собрал отказ.
local BROKEN_STATUS = 500

--- Ловушка для `xpcall`: снимает стек там, где он ещё есть.
---
--- После возврата из `xpcall` стека уже нет — он размотан, — поэтому
--- запомнить его можно только здесь.
---@param raised any
---@return table
local function caught(raised)
    -- Уровень 2: первый — сама ловушка, и в записи она не нужна.
    return { raised = raised, traceback = debug.traceback('', 2) }
end

--- Стек, который причина принесла с собой.
---
--- Сосед, поймавший бросок сам, — конвейер слоёв первым, — отдаёт
--- поломку отказом-таблицей: слово в `message`, стек места броска
--- в `traceback`. Снять стек здесь уже нечем — его размотал чужой
--- перехват, — и без принесённого запись о поломке говорила бы, что
--- сломалось, но не как туда пришли. Признак один и явный: строка в поле
--- `traceback`, и ничего сверх неё не угадывается.
---
--- Поле читается мимо метатаблицы: о причине пишут там, где поломка уже
--- случилась, и чужой `__index`, бросив, унёс бы с собой запись о первой.
---@param cause any
---@return string|nil
local function carried(cause)
    if type(cause) ~= 'table' then
        return nil
    end

    local traceback = rawget(cause, 'traceback')

    if type(traceback) ~= 'string' then
        return nil
    end

    return traceback
end

--- Поле договора границы: строка либо своё умолчание.
---
--- Поле не той породы — всё равно что не сказанное: таблица или число
--- на месте слова уехали бы клиенту как есть, а сказать человеку им
--- нечего. Отказать здесь исключением нельзя — ответ уже собирается, —
--- поэтому берётся своё.
---@param value any
---@param fallback string
---@return string
local function worded(value, fallback)
    if type(value) ~= 'string' then
        return fallback
    end

    return value
end

--- Принимает чужой отказ границы HTTP как свой.
---
--- Статус сохраняется целиком: его выбрал тот, кто отказал, и он один
--- знает, почему именно этот. Опознаватель тоже берётся как есть —
--- новый увёл бы человека к записи, которой нет: о происшествии уже
--- написал отказавший, и номер в журнале лежит его.
---
--- Слово идёт наружу по тому же праву, что и слово `explain`: договор
--- границы называет `message` строкой для человека, то есть написанной
--- разработчиком. Чужой текст библиотеки в нём — нарушение договора
--- на той стороне, и поймать его отсюда нечем.
---@param refusal TntErrorRefusal
---@return TntError
local function adopted(refusal)
    local said = secret.scrub(worded(refusal.message, REFUSED_MESSAGE))

    return failure.new({
        code = worded(refusal.code, Module.REFUSED),
        status = refusal.status,
        -- Имя рода и подробность совпадают: подстановок в чужом слове нет,
        -- и `problem` покажет его один раз, а не дважды.
        title = said,
        message = said,
        expected = refusal.status < BROKEN_STATUS,
        incident = refusal.incident,
        headers = refusal.headers,
        params = {},
    })
end

---@class TntErrorRegistry
---@field catalog TntErrorCatalog Объявленные отказы
---@field settings TntErrorSettings Действующие настройки
local Registry = {}
Registry.__index = Registry

--- Отдельный каталог отказов со своими настройками.
---@param opts TntErrorOptions|nil
---@return TntErrorRegistry
function Module.registry(opts)
    return setmetatable({
        catalog = catalog.new(),
        settings = options.checked(opts),
    }, Registry)
end

--- Объявляет отказ.
---@param code string Код вида `customer.not_found`
---@param declaration TntErrorDeclaration
---@return string code
function Registry:define(code, declaration)
    return self.catalog:define(code, declaration)
end

--- Меняет объявление уже объявленного отказа.
---
--- Слово пакета написано для всех приложений сразу, и своему человеку
--- приложение говорит иначе — особенно то самое слово при 500, которое
--- он и увидит чаще прочих. Заводить ради этого второй код о том же
--- самом не нужно: объявление заменяется.
---@param code string
---@param declaration TntErrorDeclaration
---@return string code
function Registry:redefine(code, declaration)
    return self.catalog:redefine(code, declaration)
end

--- Объявление отказа либо nil.
---@param code any
---@return TntErrorDeclaration|nil
function Registry:defined(code)
    return self.catalog:find(code)
end

--- Все объявленные коды по алфавиту.
---@return string[]
function Registry:codes()
    return self.catalog:codes()
end

--- Заводит ожидаемый отказ по объявленному коду.
---@param code string
---@param params table|nil Подстановки в строку
---@return TntError
function Registry:new(code, params)
    local declared = self.catalog:find(code)

    if declared == nil then
        error(
            ('отказ %s не объявлен: объявите его define до первого new'):format(
                tostring(code)
            )
        )
    end

    local clean = secret.clean(nil, params or {})

    return failure.new({
        code = code,
        status = declared.status,
        title = declared.title,
        type = declared.type,
        message = catalog.fill(declared.message, clean),
        expected = true,
        params = clean,
    })
end

--- Заводит внутреннюю поломку и пишет о ней в журнал.
---
--- Причина ложится в запись описанием, а не печатью: простая таблица
--- печатает только свой адрес, и номер происшествия вёл бы в запись
--- `table: 0x…`, из которой не понять, что сломалось.
---
--- Стек берётся снятый перехватом каталога, а без него — принесённый
--- самой причиной: снятый — стек заведомо, а поле чужой таблицы — стек
--- только по договору.
---@param cause any Из-за чего случилось
---@param traceback string|nil Стек на месте поломки
---@return TntError
function Registry:internal(cause, traceback)
    local mark = incident.next()
    local reason = secret.describe(cause)
    local stack = traceback or carried(cause)
    -- Объявление есть всегда: оно заводится вместе с каталогом, а убрать
    -- его нечем — повторно занять тот же код `define` не даёт.
    local declared = assert(self.catalog:find(Module.INTERNAL))

    -- Запись делается здесь, а не там, где отказ показывают: показать
    -- его могут и не захотеть — поймать, посмотреть и пойти другой
    -- дорогой, — а происшествие всё равно случилось.
    log.error('внутренняя поломка', {
        incident = mark,
        reason = reason,
        traceback = stack,
    })

    local broken = failure.new({
        code = Module.INTERNAL,
        status = declared.status,
        title = declared.title,
        -- Род отказа берётся из объявления наравне со статусом и словом:
        -- иначе `redefine` внутренней поломки принимал бы `type` и молча
        -- терял его, а в ответе оставался прежний URI.
        type = declared.type,
        message = catalog.fill(declared.message, { incident = mark }),
        expected = false,
        incident = mark,
        params = {},
        cause = reason,
        traceback = stack,
    })

    -- Крюкам — после записи и с причиной как есть (`tnt.error.hook`):
    -- номер уже ведёт в журнал, а описание причины — строка для журнала,
    -- и слушателю со своим разбором его мало.
    return hook.fired(broken, cause)
end

--- Приводит что угодно к отказу.
---
--- Чужая строка становится внутренней поломкой, а не показывается как
--- есть, и это главное решение пакета. Про текст, которого мы не писали,
--- неизвестно ничего: в нём бывает путь до файла, имя пользователя базы
--- и ответ чужого сервера целиком.
---
--- Спрашивается по порядку: наш ли отказ, чужой ли отказ границы HTTP,
--- не брошен ли один из них под чужим перехватом, и только потом —
--- внутренняя поломка. Второй вопрос появился из-за роутера: 404 и 405
--- он собирает сам, до всякого обработчика, и считать их поломкой
--- значило отвечать 500 на промах по адресу — с новым опознавателем
--- и второй записью в журнале об одном и том же запросе. Третий —
--- из-за конвейера слоёв: брошенный обработчиком отказ доходит от него
--- отказом упавшего шага, а сам лежит внутри (`failure.thrown`): не
--- заглянув туда, каталог ответил бы на один и тот же отказ своим
--- статусом, вернись он парой, и поломкой с номером происшествия, будь
--- он брошен, — хотя `guard`, поймав бросок сам, пропускает его как есть.
---@param value any
---@param traceback string|nil
---@return TntError
function Registry:of(value, traceback)
    if failure.is(value) then
        return value
    end

    if failure.refuses(value) then
        return adopted(value)
    end

    local raised = failure.thrown(value)

    if raised ~= nil then
        return self:of(raised)
    end

    return self:internal(value, traceback)
end

--- Накрывает причину объявленным отказом.
---
--- Второй аргумент — только код из каталога, и это главное, чем вызов
--- отличается от `explain`. По виду строки пакет ничего не решает:
--- раньше решал, и чужое `timeout` — строка без пробелов, из латиницы —
--- уходило искать себя в каталоге, не находилось и роняло узел. Отказ
--- превращался в 500 там, где хватило бы внятного слова.
---@param err any Причина
---@param code string Код объявленного отказа
---@param params table|nil Подстановки в строку
---@return TntError
function Registry:wrap(err, code, params)
    if self.catalog:find(code) == nil then
        error(UNKNOWN_CODE:format(tostring(code), secret.describe(err)))
    end

    local cause = self:of(err)
    local layer = self:new(code, params)

    layer.cause = cause
    -- Опознаватель и стек наследуются: запись о происшествии уже
    -- написана, и второй номер увёл бы человека туда, где ничего нет.
    layer.incident = cause.incident
    layer.traceback = cause.traceback

    return layer
end

--- Накрывает причину готовым словом для человека.
---
--- Меняется только то, что сказано об этом случае: род отказа, статус
--- и опознаватель остаются от причины, потому что случилось всё то же
--- самое, просто сказать об этом надо иначе.
---
--- Слово идёт наружу, каким бы оно ни было, — и это законно ровно
--- потому, что его написал разработчик прямо здесь, а не принесла чужая
--- библиотека. Чужой текст кладут первым аргументом, а не вторым.
---@param err any Причина
---@param message string Слово для человека
---@return TntError
function Registry:explain(err, message)
    -- Негодное слово отвергается исключением, как и негодный код в `wrap`:
    -- `explain(err, nil)` показал бы человеку строку «nil», а таблица
    -- доехала бы до клиента целиком. Это промах кода, а не отказ клиенту.
    if type(message) ~= 'string' then
        error(
            ('слово для человека пишется строкой, а не %s: explain берёт готовое слово вторым аргументом'):format(
                type(message)
            )
        )
    end

    local cause = self:of(err)

    return failure.new({
        code = cause.code,
        status = cause.status,
        title = cause.title,
        type = cause.type,
        message = secret.scrub(message),
        expected = cause.expected,
        incident = cause.incident,
        -- Заголовки едут со статусом: слово поменялось, а `Allow` при 405
        -- по-прежнему требует RFC 9110 — и требует он его от ответа,
        -- а не от того, кто первым его собрал.
        headers = cause.headers,
        params = cause.params,
        -- Своё слово разработчика по коду не переводится: строка кода
        -- сказала бы о случае меньше, чем он сам.
        explained = true,
        cause = cause,
        traceback = cause.traceback,
    })
end

--- Зовёт функцию под перехватом.
---
--- Паника становится внутренней поломкой с опознавателем и записью
--- в журнале, ожидаемый отказ проходит как есть. Стек остаётся в записи,
--- а не в ответе: по нему видно устройство узла, и наружу его показывать
--- нельзя.
---
--- Возвращается пара, а не все значения функции: договор пакетов —
--- «значение, отказ», и третьему значению в ней негде разместиться.
---@param fn fun(...): any
---@param ... any Аргументы функции
---@return any value
---@return TntError|nil err
function Registry:guard(fn, ...)
    local args = { ... }
    local count = select('#', ...)

    local ok, first, second = xpcall(function()
        return fn(unpack(args, 1, count))
    end, caught)

    if not ok then
        return nil, self:of(first.raised, first.traceback)
    end

    -- Пара `nil, err` — тоже отказ, и его приводят к общему виду здесь.
    -- Иначе чужая строка доходит до сервера как есть.
    if first == nil and second ~= nil then
        return nil, self:of(second)
    end

    return first, second
end

--- Собирает тело ответа.
---
--- Запрос нужен переводу: по нему слово находит язык и тогда, когда
--- отказ рисуют за слоем языка. Без запроса слово ищет язык само.
---@param err any
---@param request any|nil Запрос, из-за которого отказали
---@return table body Таблица для ответа
---@return integer status Статус ответа
function Registry:render(err, request)
    local shown = translation.of(self:of(err), request, self.settings)

    return render.of(shown, self.settings), shown.status
end

--- Страница отказа, если её просит клиент и каталог её отдаёт.
---
--- Спрашивается запрос, а не путь и не способ: кто пришёл — браузер или
--- сценарий, — сказано заголовком `Accept` (`tnt.error.accept`).
---@param self TntErrorRegistry
---@param shown TntError
---@param request any
---@return string|nil
local function paged(self, shown, request)
    if self.settings.page == false or not accept.wants_page(request) then
        return nil
    end

    return page.of(shown, request, self.settings)
end

--- Собирает ответ целиком: статус, заголовки и тело.
---
--- Тело — строка, а не таблица: ответ отсюда уходит в `http.server` как
--- есть, а он таблицу в теле печатает клиенту как «table: 0x...». Кому
--- нужна таблица — берёт `render`, который её и отдаёт.
---
--- Заголовки отказа переезжают в ответ: `Allow` при 405 требует RFC 9110
--- от ответа, а не от того, кто отказ собрал. Подпись ответа при этом
--- остаётся за тем, кто собрал тело, то есть за этим пакетом: чужой
--- `content-type` описывал бы не то тело, которое поедет.
---
--- Запрос нужен двоим: по нему выбирается вид ответа — страница
--- браузеру или прежнее тело сценарию, — и по нему же перевод находит
--- язык слова. Без запроса ответ прежний.
---@param err any
---@param request any|nil Запрос, из-за которого отказали
---@return table
function Registry:response(err, request)
    local shown, language = translation.of(self:of(err), request, self.settings)
    local headers = {}

    for name, value in pairs(shown.headers or {}) do
        headers[name] = value
    end

    translation.annotate(headers, self.settings, language)

    local drawn = paged(self, shown, request)

    if drawn ~= nil then
        headers['content-type'] = page.CONTENT_TYPE

        return { status = shown.status, headers = headers, body = drawn }
    end

    headers['content-type'] = self.settings.content_type

    return {
        status = shown.status,
        headers = headers,
        body = json.encode(render.of(shown, self.settings)),
    }
end

--- Слой для `tnt.middleware`.
---@return fun(request: any, nxt: fun(request: any): any): any
function Registry:middleware()
    return web.middleware(self)
end

--- Обработчик отказа для `tnt.router`.
---@return fun(err: any, request: any): table
function Registry:handler()
    return web.handler(self)
end

--- Что настроено. Секретов здесь нет и быть не может: каталог хранит
--- только объявления.
---@return table
function Registry:status()
    return {
        view = render.name_of(self.settings.view),
        content_type = self.settings.content_type,
        type_base = self.settings.type_base,
        instance_base = self.settings.instance_base,
        page = page.name_of(self.settings.page),
        debug = self.settings.debug,
        translate = self.settings.translate ~= nil,
        codes = #self.catalog:codes(),
    }
end

---@type TntErrorRegistry|nil
local shared

--- Общий на процесс каталог отказов; заводится при первом обращении.
---@return TntErrorRegistry
function Module.default()
    if shared == nil then
        shared = Module.registry(nil)
    end

    return shared
end

--- Настраивает общий каталог.
---@param opts TntErrorOptions|nil
function Module.configure(opts)
    Module.default().settings = options.checked(opts)
end

--- Поле отказа, если это наш отказ.
---@param err any
---@param name string
---@return any
local function field_of(err, name)
    if not failure.is(err) then
        return nil
    end

    return err[name]
end

--- Тот ли это отказ.
---
--- Сверяется верхний слой: обёртка строкой код не меняет, поэтому
--- «клиента нет» остаётся «клиента нет» на любой высоте.
---@param err any
---@param code string
---@return boolean
function Module.is(err, code)
    local known = field_of(err, 'code')

    -- Сравнение пустого с пустым иначе объявляло бы своим отказом любую
    -- чужую строку, о которой спросили без кода.
    return known ~= nil and known == code
end

--- Код отказа либо nil, если отказ не наш.
---@param err any
---@return string|nil
function Module.code_of(err)
    return field_of(err, 'code')
end

--- Опознаватель происшествия либо nil.
---@param err any
---@return string|nil
function Module.incident_of(err)
    return field_of(err, 'incident')
end

--- Ожидаемый это отказ или внутренняя поломка.
---@param err any
---@return boolean
function Module.expected(err)
    return field_of(err, 'expected') == true
end

--- Объявляет отказ в общем каталоге.
---@param code string
---@param declaration TntErrorDeclaration
---@return string code
function Module.define(code, declaration)
    return Module.default():define(code, declaration)
end

--- Меняет объявление отказа в общем каталоге.
---@param code string
---@param declaration TntErrorDeclaration
---@return string code
function Module.redefine(code, declaration)
    return Module.default():redefine(code, declaration)
end

--- Объявление отказа из общего каталога либо nil.
---@param code any
---@return TntErrorDeclaration|nil
function Module.defined(code)
    return Module.default():defined(code)
end

--- Все коды общего каталога по алфавиту.
---@return string[]
function Module.codes()
    return Module.default():codes()
end

--- Заводит ожидаемый отказ по объявленному коду.
---@param code string
---@param params table|nil
---@return TntError
function Module.new(code, params)
    return Module.default():new(code, params)
end

--- Приводит что угодно к отказу.
---@param value any
---@return TntError
function Module.of(value)
    return Module.default():of(value)
end

--- Накрывает причину объявленным отказом.
---@param err any
---@param code string Код объявленного отказа
---@param params table|nil
---@return TntError
function Module.wrap(err, code, params)
    return Module.default():wrap(err, code, params)
end

--- Накрывает причину готовым словом для человека.
---@param err any
---@param message string
---@return TntError
function Module.explain(err, message)
    return Module.default():explain(err, message)
end

--- Зовёт функцию под перехватом.
---@param fn fun(...): any
---@param ... any
---@return any value
---@return TntError|nil err
function Module.guard(fn, ...)
    return Module.default():guard(fn, ...)
end

--- Собирает тело ответа.
---@param err any
---@param request any|nil Запрос, из-за которого отказали: по нему перевод находит язык
---@return table body
---@return integer status
function Module.render(err, request)
    return Module.default():render(err, request)
end

--- Собирает ответ целиком: статус, заголовки и тело.
---@param err any
---@param request any|nil Запрос, из-за которого отказали: по нему выбираются вид и язык слова
---@return table
function Module.response(err, request)
    return Module.default():response(err, request)
end

--- Слой для `tnt.middleware`.
---@return fun(request: any, nxt: fun(request: any): any): any
function Module.middleware()
    return Module.default():middleware()
end

--- Обработчик отказа для `tnt.router`.
---@return fun(err: any, request: any): table
function Module.handler()
    return Module.default():handler()
end

--- Крюки внутренней поломки — общие на процесс, для всех каталогов:
--- `hook(имя, крюк)` ставит, заменяет или снимает, `hooks()` перечисляет
--- по порядку постановки (`tnt.error.hook`).
Module.hook = hook.set
Module.hooks = hook.names

--- Что настроено у общего каталога.
---@return table
function Module.status()
    return Module.default():status()
end

return Module
