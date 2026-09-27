--- Представление отказа наружу.
---
--- По умолчанию — вид RFC 9457 (`application/problem+json`). Он выбран
--- не из любви к стандартам: у отказа появляется опознаваемый род (`type`),
--- и клиент перестаёт разбирать текст сообщения, чтобы понять, что
--- случилось. Разбор текста — это то, что ломается при первой же правке
--- строки, в том числе при переводе.
---
--- Что чем становится, по RFC 9457:
---
---   type      — URI рода отказа, собирается из кода;
---   title     — краткое имя рода, одно и то же от случая к случаю;
---   status    — тот же статус, что и у самого ответа;
---   detail    — что случилось именно в этот раз;
---   instance  — URI происшествия, собирается из опознавателя.
---
--- Отсюда и разделение «шаблон — строка»: `title` берётся из шаблона
--- («Клиента №{id} нет»), `detail` — из подставленной строки («Клиента
--- №7 нет»). RFC прямо просит, чтобы `title` не менялся от случая
--- к случаю, и это не придирка: по нему клиент группирует отказы
--- в отчётах.
---
--- Спецификация разрешает свои поля сверх перечисленных, и их здесь два:
--- `code` — код отказа как он записан в каталоге, и `incident` —
--- опознаватель происшествия без обёртки в URI. Оба уже есть в `type`
--- и `instance`, но выковыривать их оттуда строковыми операциями клиент
--- не должен.
---
--- Второй вид — простой `{ error, message }`. Он здесь потому, что
--- готовые панели и клиенты ждут разного, и заставлять целую панель
--- переучиваться ради красивого ответа — плохая сделка.
---
--- Видов, однако, не два, а сколько нужно: настройкой `view` кладётся
--- своя функция `(отказ, настройки) -> тело`. Готовая панель ждёт ровно
--- то тело, которое умеет разбирать, — например `{ error = { status,
--- message } }`, — и собранная из чужих кусков она не переучится вовсе.
--- Пакет в этом случае отдаёт всё, что у него есть: каталог, подстановки,
--- вырезание тайн и опознаватель, — а тело собирает тот, кому отвечать.

local Module = {}

--- Чем подписывается ответ каждого готового вида.
Module.CONTENT_TYPE = {
    problem = 'application/problem+json',
    simple = 'application/json',
}

--- Чем подписывается ответ, собранный своей функцией.
---
--- Тело она отдаёт таблицей, а таблица уезжает клиенту тем же JSON, что
--- и у простого вида. Кому нужно другое — говорит это настройкой
--- `content_type`: угадать за чужой вид нечем.
Module.DEFAULT_CONTENT_TYPE = 'application/json'

--- Как зовётся вид, у которого нет имени.
---
--- Своя функция в выкладке `status()` не показывается: прочитать её
--- глазами нечем, а место вида занять надо.
Module.CUSTOM = 'custom'

--- Вид RFC 9457.
---@param err TntError
---@param settings TntErrorSettings
---@return table
local function problem(err, settings)
    local body = {
        type = err.type or (settings.type_base .. err.code),
        title = err.title,
        status = err.status,
        code = err.code,
    }

    -- Подробность пишется только тогда, когда она добавляет что-то
    -- к имени рода: у отказа без подстановок она дословно его повторяет,
    -- и клиент получает одну и ту же фразу дважды.
    if err.message ~= err.title then
        body.detail = err.message
    end

    if err.incident ~= nil then
        body.incident = err.incident
        body.instance = settings.instance_base .. err.incident
    end

    return body
end

--- Простой вид: код и строка, больше ничего.
---@param err TntError
---@return table
local function simple(err)
    return {
        error = err.code,
        message = err.message,
        -- Опознаватель остаётся и здесь: без него человеку нечего назвать
        -- дежурному, и происшествие теряется.
        incident = err.incident,
    }
end

--- Виды представления по именам.
local VIEWS = {
    problem = problem,
    simple = simple,
}

--- Имена видов по алфавиту.
---
--- Из них собирается список допустимых значений настройки: перечислить
--- их там второй раз значило бы однажды добавить вид, о котором проверка
--- настроек не знает, — и получить отказ на законном имени.
Module.NAMES = {}

for name in pairs(VIEWS) do
    table.insert(Module.NAMES, name)
end

table.sort(Module.NAMES)

--- Знаком ли такой готовый вид.
---@param view any
---@return boolean
function Module.knows(view)
    return VIEWS[view] ~= nil
end

--- Как называется вид в выкладке настроек.
---@param view TntErrorView
---@return string
function Module.name_of(view)
    if type(view) == 'function' then
        return Module.CUSTOM
    end

    return view
end

--- Чем подписывается ответ этого вида.
---@param view TntErrorView
---@return string
function Module.content_type_of(view)
    return Module.CONTENT_TYPE[view] or Module.DEFAULT_CONTENT_TYPE
end

--- Собирает тело ответа.
---@param err TntError
---@param settings TntErrorSettings
---@return table body
function Module.of(err, settings)
    local view = settings.view

    if type(view) == 'function' then
        -- Своя функция получает отказ целиком — со статусом, кодом,
        -- опознавателем и подстановками: что из этого попадёт в тело,
        -- решает она.
        return view(err, settings)
    end

    -- Имя вида уже проверено настройками, и незнакомого здесь не бывает.
    return assert(VIEWS[view])(err, settings)
end

return Module
