--- Страница отказа: то, что видит человек, открывший адрес браузером.
---
--- Тело отказа написано для машины: код, слово, номер происшествия.
--- Человеку в браузере оно показывается строкой с фигурными скобками,
--- и по ней не понять ни что случилось, ни что делать дальше. Поэтому
--- у отказа есть второй вид — страница, и уходит она тому, кто её
--- попросил (`tnt.error.accept`).
---
--- Страниц здесь две, и различие между ними — всё содержание модуля.
---
--- **Страница человеку** говорит ровно то же, что и тело отказа: код
--- ответа, заголовок по коду, слово разработчика и номера, по которым
--- происшествие находят в журнале. Ни стека, ни путей, ни заголовков
--- запроса: их читает кто угодно, а помочь они не могут никому.
---
--- **Страница разбора** показывает место в коде, цепочку отказа, стек,
--- запрос и его заголовки. Она рисуется только по настройке `debug`
--- и только внутренней поломке — тому единственному случаю, когда
--- смотреть в самом деле не на что. Тайны из неё вырезаны тем же
--- правилом, каким они вырезаются из записи журнала: список подсказок
--- один на все пакеты и живёт в `tnt-log`.
---
--- Разметка рисуется движком `tnt-template` из строки, лежащей здесь же,
--- а не собирается склейкой: склейка однажды забывает экранирование,
--- и забывает его ровно там, где значение пришло от посетителя —
--- в пути запроса и в заголовках. Из строки, а не из файла: страница
--- отказа обязана нарисоваться и тогда, когда сломался каталог страниц
--- приложения.
---
--- Своя страница приложения — настройка `page`: функция получает те же
--- данные и отдаёт разметку. Сорвалась или отдала не строку — человек
--- всё равно получает страницу, встроенную: отказ, оставшийся без ответа
--- из-за опечатки в шаблоне, хуже некрасивой страницы.

local template = require('tnt.template')

local catalog = require('tnt.error.catalog')
local context = require('tnt.context')
local failure = require('tnt.error.failure')
local secret = require('tnt.error.secret')

local log = require('tnt.log').new('tnt.error')

local Module = {}

--- Чем подписан ответ страницей.
---
--- С кодировкой: страница написана по-русски, а без `charset` браузер
--- читает её в своей и показывает вопросительные знаки.
Module.CONTENT_TYPE = 'text/html; charset=utf-8'

--- Заголовок страницы по коду ответа.
---
--- Слово из каталога говорит, что случилось в этот раз, а заголовок —
--- что это за беда вообще: человек узнаёт её по нему раньше, чем прочтёт
--- строку. Перечислены коды, которыми отвечает граница HTTP; 419 здесь
--- нет — его нет в RFC 9110, и подделку формы отвергают кодом 403.
Module.TITLES = {
    [400] = 'Запрос не понят',
    [401] = 'Нужно войти',
    [403] = 'Сюда нельзя',
    [404] = 'Страницы нет',
    [405] = 'Так сюда нельзя',
    [408] = 'Запрос не пришёл вовремя',
    [413] = 'Запрос слишком велик',
    [422] = 'Данные не подошли',
    [429] = 'Слишком часто',
    [500] = 'Что-то сломалось',
    [502] = 'Соседняя служба молчит',
    [503] = 'Сейчас не работаем',
    [504] = 'Ответа не дождались',
}

--- Заголовок для кода, которого нет в перечне.
Module.DEFAULT_TITLE = 'Не получилось'

--- Как зовётся в выкладке настроек встроенная страница, своя и её запрет.
Module.BUILTIN = 'builtin'
Module.CUSTOM = 'custom'
Module.OFF = 'off'

--- Данные страницы: их же получает и своя страница приложения.
---@class TntErrorPageView
---@field status integer Код ответа
---@field title string Заголовок по коду ответа
---@field message string Слово для человека — то же, что в теле отказа
---@field incident string|nil Опознаватель происшествия
---@field request_id string|nil Опознаватель запроса из контекста файбера
---@field details TntErrorPageDetails|nil Подробности; есть только у страницы разбора

--- Подробности поломки: страница разбора и ничто иное.
---@class TntErrorPageDetails
---@field place string|nil Место в коде: первый кадр стека на Lua
---@field chain string[] Цепочка отказа сверху вниз, со всеми нижними слоями
---@field traceback string|nil Стек на месте поломки
---@field method string|nil Способ запроса
---@field path string|nil Путь запроса
---@field query { name: string, value: string }[] Поля строки запроса без тайн
---@field headers { name: string, value: string }[] Заголовки запроса без тайн

--- Разметка встроенной страницы.
---
--- Вид простой нарочно: ни одного обращения наружу — ни за стилями,
--- ни за шрифтами, ни за картинками. Страница отказа рисуется и тогда,
--- когда раздача файлов — как раз то, что сломалось.
local SOURCE = [==[
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{ status }} — {{ title }}</title>
<style>
body { margin: 0; padding: 2rem 1rem; font: 16px/1.5 system-ui, sans-serif; color: #1f2328; background: #f6f7f9; }
main { max-width: 46rem; margin: 0 auto; }
.status { margin: 0; font-size: 3rem; font-weight: 700; color: #8a919a; }
h1 { margin: 0 0 1rem; font-size: 1.6rem; }
h2 { margin: 1.5rem 0 0.5rem; font-size: 1rem; text-transform: uppercase; color: #8a919a; }
p { margin: 0 0 0.5rem; }
code, pre { font-family: ui-monospace, monospace; font-size: 0.9rem; }
pre { overflow-x: auto; padding: 0.75rem; background: #fff; border: 1px solid #e1e4e8; }
.marks { margin: 1rem 0 0; color: #57606a; font-size: 0.9rem; }
table { width: 100%; border-collapse: collapse; font-size: 0.9rem; }
th { width: 14rem; text-align: left; vertical-align: top; font-weight: 600; }
th, td { padding: 0.25rem 0.5rem 0.25rem 0; border-bottom: 1px solid #e1e4e8; word-break: break-all; }
ol { margin: 0; padding-left: 1.2rem; }
</style>
</head>
<body>
<main>
<p class="status">{{ status }}</p>
<h1>{{ title }}</h1>
<p>{{ message }}</p>
@if (incident or request_id)
<p class="marks">
@if (incident)Происшествие <code>{{ incident }}</code>. @endif
@if (request_id)Запрос <code>{{ request_id }}</code>. @endif
</p>
@endif
@if (details)
@if (details.place)
<h2>Где сломалось</h2>
<p><code>{{ details.place }}</code></p>
@endif
<h2>Цепочка отказа</h2>
<ol>
@for (_, said in ipairs(details.chain))<li>{{ said }}</li>
@endfor
</ol>
<h2>Запрос</h2>
<p><code>{{ details.method }} {{ details.path }}</code></p>
@if (details.query[1])
<table>
@for (_, field in ipairs(details.query))<tr><th>{{ field.name }}</th><td>{{ field.value }}</td></tr>
@endfor
</table>
@endif
<h2>Заголовки</h2>
<table>
@for (_, header in ipairs(details.headers))<tr><th>{{ header.name }}</th><td>{{ header.value }}</td></tr>
@endfor
</table>
@if (details.traceback)
<h2>Стек</h2>
<pre>{{ details.traceback }}</pre>
@endif
@endif
</main>
</body>
</html>
]==]

--- Переведённая разметка; перевод один на процесс.
---
--- Лениво, а не при загрузке: загрузка модуля не должна ничего делать,
--- а страница отказа рисуется в лучшем случае никогда.
---@type (fun(data: table|nil): string)|nil
local drawing

--- Кадр стека, у которого есть файл и строка: `путь:строка: что делал`.
---
--- Верхний кадр обычно `[C]: in function 'error'` — им поломка сказана,
--- но не объяснена, и человеку нужен первый кадр на Lua. Такой кадр
--- начинается с пути и номера строки через двоеточие, и по ним он
--- и узнаётся; кадры без них образец пропускает сам.
local FRAME = '\n%s*([^%s]+:%d+:[^\n]*)'

--- Место в коде: первый кадр стека на Lua.
---@param traceback any
---@return string|nil
local function place_of(traceback)
    if type(traceback) ~= 'string' then
        return nil
    end

    local frame = traceback:match(FRAME)

    if frame == nil then
        return nil
    end

    return secret.scrub(frame)
end

--- Место в слове поломки: `файл:строка` перед объяснением.
---
--- Имя файла двоеточий не содержит, номер строки — только цифры: по этим
--- двум приметам место и находится среди обычных слов.
local PLACE = '([^%s:]+:%d+):'

--- Место, названное словами цепочки: `файл:строка`.
---
--- Стека у поломки бывает и нет: бросок, пойманный чужим `pcall`
--- и отданный парой `nil, err` строкой, приходит сюда уже без стека.
--- Но место в строке остаётся — его пишет началом сообщения сама Lua, —
--- и оно отвечает на тот же вопрос «где сломалось».
---
--- Ищется снизу вверх: нижний слой цепочки — та самая поломка, верхние
--- уже накрыты словом разработчика.
---@param chain string[]
---@return string|nil
local function told(chain)
    for at = #chain, 1, -1 do
        local place = chain[at]:match(PLACE)

        if place ~= nil then
            return place
        end
    end

    return nil
end

--- Пары таблицы списком по алфавиту имён.
---
--- Списком, а не таблицей: порядок ключей в Lua не задан, и страница
--- перекладывала бы заголовки при каждом обновлении. Значения приходят
--- уже без тайн, а описанием — потому что значением поля запроса бывает
--- и список: `tostring` показал бы его адресом в памяти.
---@param values any
---@return { name: string, value: string }[]
local function listed(values)
    local shown = {}

    if type(values) ~= 'table' then
        return shown
    end

    local said = {}
    local names = {}

    for name, value in pairs(secret.clean(nil, values)) do
        local key = tostring(name)

        said[key] = secret.describe(value)
        table.insert(names, key)
    end

    -- Порядок — общий для строк, а не свой: своё сравнение отличалось бы
    -- от встроенного только тем, как его однажды напишут неверно.
    table.sort(names)

    for _, name in ipairs(names) do
        table.insert(shown, { name = name, value = said[name] })
    end

    return shown
end

--- Подробности поломки — только для страницы разбора.
---
--- Цепочка отказа берётся целиком, со всеми нижними слоями: наружу они
--- не идут никогда, а здесь как раз они и объясняют, что случилось.
---@param err TntError
---@param request any
---@return TntErrorPageDetails
local function detailed(err, request)
    local said = {}

    for _, layer in ipairs(failure.chain(err)) do
        table.insert(said, secret.scrub(layer))
    end

    local given = type(request) == 'table' and request or {}

    return {
        place = place_of(err.traceback) or told(said),
        chain = said,
        traceback = type(err.traceback) == 'string' and secret.scrub(err.traceback) or nil,
        method = given.method,
        path = given.path,
        query = listed(given.query),
        headers = listed(given.headers),
    }
end

--- Данные страницы: то же, что уходит и своей странице приложения.
---
--- Опознаватель запроса берётся из контекста файбера, а не из полей
--- запроса: оттуда же его берёт журнал в каждую запись, и номер
--- на странице заведомо тот самый, по которому запись найдут.
---@param err TntError
---@param request any
---@param settings TntErrorSettings
---@return TntErrorPageView
function Module.view(err, request, settings)
    ---@type TntErrorPageView
    local shown = {
        status = err.status,
        title = Module.TITLES[err.status] or Module.DEFAULT_TITLE,
        message = err.message,
        incident = err.incident,
        -- Ключ объявлен строковым, и другого значения под ним не бывает;
        -- вывод типов об этом не знает.
        request_id = context.get(context.REQUEST_ID) --[[@as string|nil]],
    }

    -- Разбор показывается одной только внутренней поломке: у ожидаемого
    -- отказа разбирать нечего — он весь сказан словом, — а страница
    -- приложения с рамкой сайта человеку полезнее и в разработке.
    if settings.debug and err.code == catalog.INTERNAL then
        shown.details = detailed(err, request)
    end

    return shown
end

--- Как страница зовётся в выкладке настроек.
---
--- Своя функция показывается словом: прочитать её глазами нечем,
--- а место в выкладке занять надо — как и у своего вида тела.
---@param value TntErrorPage
---@return string
function Module.name_of(value)
    if type(value) == 'function' then
        return Module.CUSTOM
    end

    if value then
        return Module.BUILTIN
    end

    return Module.OFF
end

--- Рисует встроенную страницу.
---@param shown TntErrorPageView
---@return string
function Module.draw(shown)
    if drawing == nil then
        drawing = template.compile(SOURCE, 'tnt.error.page')
    end

    return drawing(shown)
end

--- Страница отказа: своя у приложения либо встроенная.
---
--- Страница разбора встроенная всегда: в разработке стек нужнее рамки
--- сайта, а приложение о нём ничего и не знает.
---@param err TntError
---@param request any
---@param settings TntErrorSettings
---@return string
function Module.of(err, request, settings)
    local shown = Module.view(err, request, settings)
    local build = settings.page

    if shown.details == nil and type(build) == 'function' then
        local ok, drawn = pcall(build, shown)

        if ok and type(drawn) == 'string' then
            return drawn
        end

        -- Пустота — не беда: у приложения просто нет страницы на этот код
        -- ответа, и рисует встроенная. Запись о таком на каждый промах
        -- по адресу засорила бы журнал.
        --
        -- А вот сорвавшаяся страница и страница, отдавшая не разметку, —
        -- это опечатка в шаблоне, и без записи она живёт незамеченной
        -- ровно до того дня, когда кто-нибудь откроет её глазами.
        if not ok or drawn ~= nil then
            log.warn('страница отказа приложения не нарисована', {
                status = shown.status,
                reason = ok and ('страница отдала %s'):format(type(drawn)) or tostring(drawn),
            })
        end
    end

    return Module.draw(shown)
end

return Module
