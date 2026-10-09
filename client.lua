local menuOpen = false

local function notify(message, kind)
    if Config.Notify then
        lib.notify({ title = 'Godzinówka', description = message, type = kind })
    end
end

local function openSalaryMenu()
    if menuOpen then return end

    menuOpen = true

    local ok, err = pcall(function()
        local amount = lib.callback.await('kurzy_salary:getBalance', false) or 0
        if amount <= 0 then
            notify('Brak środków do odebrania lub zbyt częste zapytanie.', 'inform')
            return
        end

        local answer = lib.alertDialog({
            header = 'Godzinówka',
            content = ('Czy chcesz odebrać godzinówkę?\nKwota: $%.2f'):format(amount),
            centered = true,
            cancel = true,
            labels = { confirm = 'Odbierz', cancel = 'Anuluj' },
        })
        if answer ~= 'confirm' then return end

        local payout = lib.callback.await('kurzy_salary:collect', false) or 0
        if payout > 0 then
            notify(('Odebrałeś $%.2f z godzinówki.'):format(payout), 'success')
        else
            notify('Nie udało się odebrać środków. Spróbuj ponownie za chwilę.', 'error')
        end
    end)

    menuOpen = false

    if not ok then
        print(('[kurzy_salary] Menu error: %s'):format(tostring(err)))
        notify('Nie udało się połączyć z systemem godzinówki.', 'error')
    end
end

exports('OpenSalaryMenu', openSalaryMenu)
