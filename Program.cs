using System.Globalization;
using System.Text;
using Npgsql;
using RealEstate;
using System.Text.Json;

Console.InputEncoding=Encoding.UTF8;
Console.OutputEncoding=Encoding.UTF8;

var settingsPath = Path.Combine(
    AppContext.BaseDirectory, "appsettings.json");

using var settings = JsonDocument.Parse(
    File.ReadAllText(settingsPath));

var cs = settings.RootElement
    .GetProperty("ConnectionStrings")
    .GetProperty("RealEstate")
    .GetString();

if (string.IsNullOrWhiteSpace(cs))
{
    Console.WriteLine("Вкажіть рядок підключення в appsettings.json.");
    return;
}

Console.WriteLine("Система управління нерухомістю • усі суми в гривнях");
Console.WriteLine("Навчальний режим: вибір агента за ID, без авторизації.");
long actor=1;
while(true)
{
    Console.WriteLine($"""

    Поточний агент: {actor}
     1 Об’єкти              2 Додати об’єкт       3 Редагувати об’єкт
     4 Видалити об’єкт      5 Відновити об’єкт    6 Клієнти
     7 Додати клієнта       8 Редагувати клієнта  9 Видалити клієнта
    10 Відновити клієнта   11 Оголошення         12 Створити оголошення
    13 Змінити ціну        14 Видалити оголошення 15 Відновити оголошення
    16 Оформити договір    17 Договори           18 Додати платіж
    19 Демонстрація відкату 20 Журнал змін        21 Історія цін
    22 Пошук нерухомості   23 Видалені записи    24 Власники
    25 Змінити агента      26 Типи нерухомості   27 Платежі й учасники
    28 Запланувати перегляд 29 Створити пропозицію 30 Перегляди й пропозиції
     0 Вийти
    """);
    var choice=Read("Дія"); if(choice=="0") break;
    try
    {
        if(choice is "16" or "19")
        {
            var listing=Id("ID оголошення"); var customer=Id("ID покупця/орендаря");
            var amount=Money("Сума договору"); var deposit=Money("Початковий платіж (0 — без платежу)");
            try
            {
                var contract=await new ContractService(cs).SignAsync(listing,customer,amount,deposit,actor,choice=="19");
                Console.WriteLine($"Створено договір {contract}. Усі зміни збережено.");
            }
            catch(PostgresException ex) when(choice=="19" && ex.SqlState=="23514" && ex.ConstraintName=="payments_amount_check")
            {
                Console.WriteLine("Очікувана помилка: від’ємний платіж. Договір, учасники, платежі, зміни оголошення та аудит відкочені.");
            }
            continue;
        }
        await using var u=await UnitOfWork.OpenAsync(cs);
        switch(choice)
        {
            case "1": Show(await u.Properties.All()); break;
            case "2": await u.Properties.Create(Id("ID типу (пункт 26)"),Read("Адреса"),Money("Площа"),Read("Опис"),Id("ID власника"),actor); break;
            case "3": await u.Properties.Update(Id("ID об’єкта"),Read("Нова адреса"),Money("Площа"),Read("Опис"),actor); break;
            case "4": await u.Properties.Delete(Id("ID об’єкта"),actor); break;
            case "5": await u.Properties.Restore(Id("ID об’єкта"),actor); break;
            case "6": Show(await u.Clients.All()); break;
            case "7": await u.Clients.Create(Read("ПІБ"),Read("Телефон"),Read("Email (можна порожній)"),actor); break;
            case "8": await u.Clients.Update(Id("ID клієнта"),Read("ПІБ"),Read("Телефон"),Read("Email"),actor); break;
            case "9": await u.Clients.Delete(Id("ID клієнта"),actor); break;
            case "10": await u.Clients.Restore(Id("ID клієнта"),actor); break;
            case "11": Show(await u.Listings.All()); break;
            case "12": await u.Listings.Create(Id("ID об’єкта"),Read("Вид: sale або rent"),Money("Ціна"),actor); break;
            case "13": await u.Listings.ChangePrice(Id("ID оголошення"),Money("Нова ціна"),actor); break;
            case "14": await u.Listings.Delete(Id("ID оголошення"),actor); break;
            case "15": await u.Listings.Restore(Id("ID оголошення"),actor); break;
            case "17": Show(await u.Contracts.All()); break;
            case "18": await u.Payments.Add(Guid.Parse(Read("UUID договору")),Money("Сума платежу"),actor); break;
            case "20": Show(await u.Reports.Audit()); break;
            case "21": Show(await u.Reports.Prices()); break;
            case "22": Show(await u.Properties.Search(Read("Слова для пошуку"))); break;
            case "23": Show(await u.Clients.All(true)); Show(await u.Properties.All(true)); Show(await u.Listings.All(true)); break;
            case "24": Show(await u.Properties.Owners()); break;
            case "25":
                var users=await u.Reports.Users(); Show(users); var selected=Id("ID агента");
                if(!users.Skip(1).Any(r=>r[0]==selected.ToString())) throw new ArgumentException("Немає активного користувача з цим ID.");
                actor=selected; break;
            case "26": Show(await u.Reports.Types()); break;
            case "27": Show(await u.Reports.Payments()); Show(await u.Reports.Participants()); break;
            case "28":
                var l=Id("ID оголошення"); var cl=Id("ID клієнта");
                var date=DateTimeOffset.Parse(Read("Дата ISO з часовим поясом, напр. 2027-01-20T14:00:00+02:00"),CultureInfo.InvariantCulture);
                await u.Listings.Viewing(l,cl,date.UtcDateTime,actor); break;
            case "29": await u.Listings.Offer(Id("ID оголошення"),Id("ID клієнта"),Money("Сума пропозиції"),actor); break;
            case "30": Show(await u.Reports.Viewings()); Show(await u.Reports.Offers()); break;
            default: Console.WriteLine("Невідома дія."); break;
        }
        await u.CommitAsync(); Console.WriteLine("Готово.");
    }
    catch(PostgresException ex) { Console.WriteLine($"БД: {ex.MessageText}. Операцію не збережено."); }
    catch(NpgsqlException) { Console.WriteLine("Не вдалося підключитися або виконати запит. Перевірте PostgreSQL та рядок підключення."); }
    catch(Exception ex) when(ex is FormatException or ArgumentException or InvalidOperationException or OverflowException)
    { Console.WriteLine($"Помилка: {ex.Message}. Операцію не збережено."); }
}
static string Read(string prompt) { Console.Write($"{prompt}: "); return Console.ReadLine()?.Trim()??"0"; }
static long Id(string prompt) { var n=long.Parse(Read(prompt)); if(n<=0) throw new ArgumentException("ID має бути додатним."); return n; }
static decimal Money(string prompt)=>decimal.Parse(Read(prompt).Replace(',','.'),NumberStyles.AllowDecimalPoint|NumberStyles.AllowLeadingSign,CultureInfo.InvariantCulture);
static void Show(List<string[]> rows)
{
    if(rows.Count==1) { Console.WriteLine("Записів немає."); return; }
    // Vertical records keep long addresses and UUIDs readable in a narrow console.
    foreach(var row in rows.Skip(1))
    { Console.WriteLine("──────────"); for(int i=0;i<row.Length;i++) Console.WriteLine($"{rows[0][i]}: {row[i]}"); }
}
