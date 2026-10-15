using Npgsql;

namespace RealEstate;

// One connection and one transaction are shared by every repository in this UoW.
public sealed class UnitOfWork : IAsyncDisposable
{
    private readonly NpgsqlConnection connection;
    private readonly NpgsqlTransaction transaction;
    private bool finished;
    public PropertyRepository Properties { get; }
    public ClientRepository Clients { get; }
    public ListingRepository Listings { get; }
    public ContractRepository Contracts { get; }
    public PaymentRepository Payments { get; }
    public ReportRepository Reports { get; }
    private UnitOfWork(NpgsqlConnection c, NpgsqlTransaction t)
    {
        connection=c; transaction=t;
        Properties=new(c,t); Clients=new(c,t); Listings=new(c,t);
        Contracts=new(c,t); Payments=new(c,t); Reports=new(c,t);
    }
    public static async Task<UnitOfWork> OpenAsync(string connectionString)
    {
        var c=new NpgsqlConnection(connectionString);
        try { await c.OpenAsync(); return new(c,await c.BeginTransactionAsync()); }
        catch { await c.DisposeAsync(); throw; }
    }
    public async Task CommitAsync() { await transaction.CommitAsync(); finished=true; }
    public async Task RollbackAsync() { await transaction.RollbackAsync(); finished=true; }
    public async ValueTask DisposeAsync()
    {
        try { if(!finished) await transaction.RollbackAsync(); }
        finally { await transaction.DisposeAsync(); await connection.DisposeAsync(); }
    }
}

public abstract class Repository(NpgsqlConnection connection,NpgsqlTransaction transaction)
{
    protected NpgsqlCommand Command(string sql,params object[] args)
    {
        var cmd=new NpgsqlCommand(sql,connection,transaction);
        foreach(var arg in args) cmd.Parameters.Add(new NpgsqlParameter { Value=arg });
        return cmd;
    }
    protected async Task Execute(string sql,params object[] args)
    {
        await using var cmd=Command(sql,args); await cmd.ExecuteNonQueryAsync();
    }
    public async Task<List<string[]>> Query(string sql,params object[] args)
    {
        await using var cmd=Command(sql,args);
        await using var reader=await cmd.ExecuteReaderAsync();
        var rows=new List<string[]> { Enumerable.Range(0,reader.FieldCount).Select(reader.GetName).ToArray() };
        while(await reader.ReadAsync())
            rows.Add(Enumerable.Range(0, reader.FieldCount)
    .Select(i =>
    {
        if (reader.IsDBNull(i))
            return "—";

        var value = reader.GetValue(i);

        if (value is DateTime date)
        {
            var local = date.Kind == DateTimeKind.Utc
                ? date.ToLocalTime()
                : date;

            return local.ToString("dd.MM.yyyy HH:mm:ss");
        }

        return Convert.ToString(value) ?? "";
    })
    .ToArray());
        return rows;
    }
}
public sealed class ClientRepository(NpgsqlConnection c,NpgsqlTransaction t):Repository(c,t)
{
    public Task<List<string[]>> All(bool deleted=false)=>Query(deleted?
        "SELECT id,full_name,phone,deleted_at FROM estate.v_deleted_clients ORDER BY id":
        "SELECT id,full_name,phone,email,updated_at,updated_by FROM estate.v_clients ORDER BY id");
    public Task Create(string name,string phone,string email,long actor)=>Execute("CALL estate.create_client($1,$2,$3,$4)",name,phone,email,actor);
    public Task Update(long id,string name,string phone,string email,long actor)=>Execute("CALL estate.update_client($1,$2,$3,$4,$5)",id,name,phone,email,actor);
    public Task Delete(long id,long actor)=>Execute("CALL estate.delete_client($1,$2)",id,actor);
    public Task Restore(long id,long actor)=>Execute("CALL estate.restore_client($1,$2)",id,actor);
}
public sealed class PropertyRepository(NpgsqlConnection c,NpgsqlTransaction t):Repository(c,t)
{
    public Task<List<string[]>> All(bool deleted=false)=>Query(deleted?
        "SELECT id,address,deleted_at FROM estate.v_deleted_properties ORDER BY id":
        "SELECT id,type_name,address,area,updated_at,updated_by FROM estate.v_properties ORDER BY id");
    public Task<List<string[]>> Search(string term)=>Query("SELECT id,address,area FROM estate.v_properties WHERE to_tsvector('simple',address || ' ' || description) @@ plainto_tsquery('simple',$1)",term);
    public Task<List<string[]>> Owners()=>Query("SELECT * FROM estate.v_property_owners ORDER BY property_id,client_id");
    public Task Create(long type,string address,decimal area,string description,long owner,long actor)=>Execute("CALL estate.create_property($1,$2,$3,$4,$5,$6)",type,address,area,description,owner,actor);
    public Task Update(long id,string address,decimal area,string description,long actor)=>Execute("CALL estate.update_property($1,$2,$3,$4,$5)",id,address,area,description,actor);
    public Task Delete(long id,long actor)=>Execute("CALL estate.delete_property($1,$2)",id,actor);
    public Task Restore(long id,long actor)=>Execute("CALL estate.restore_property($1,$2)",id,actor);
}
public sealed class ListingRepository(NpgsqlConnection c,NpgsqlTransaction t):Repository(c,t)
{
    public Task<List<string[]>> All(bool deleted=false)=>Query(deleted?
        "SELECT id,property_id,price,status,deleted_at FROM estate.v_deleted_listings ORDER BY id":
        "SELECT id,property_id,address,kind,price FROM estate.v_active_listings ORDER BY id");
    public Task Create(long property,string kind,decimal price,long actor)=>Execute("CALL estate.create_listing($1,$2,$3,$4)",property,kind,price,actor);
    public Task ChangePrice(long id,decimal price,long actor)=>Execute("CALL estate.change_listing_price($1,$2,$3)",id,price,actor);
    public Task Delete(long id,long actor)=>Execute("CALL estate.delete_listing($1,$2)",id,actor);
    public Task Restore(long id,long actor)=>Execute("CALL estate.restore_listing($1,$2)",id,actor);
    public Task Close(long id,long actor)=>Execute("CALL estate.close_listing($1,$2)",id,actor);
    public Task Offer(long listing,long client,decimal amount,long actor)=>Execute("CALL estate.create_offer($1,$2,$3,$4)",listing,client,amount,actor);
    public Task Viewing(long listing,long client,DateTime starts,long actor)=>Execute("CALL estate.schedule_viewing($1,$2,$3,$4)",listing,client,starts,actor);
}
public sealed class ContractRepository(NpgsqlConnection c,NpgsqlTransaction t):Repository(c,t)
{
    public Task Create(Guid id,long listing,decimal amount,long actor)=>Execute("CALL estate.create_contract($1,$2,$3,$4)",id,listing,amount,actor);
    public Task Participant(Guid id,long client,string role,long actor)=>Execute("CALL estate.add_contract_participant($1,$2,$3,$4)",id,client,role,actor);
    public Task<List<string[]>> All()=>Query("SELECT * FROM estate.v_contracts ORDER BY signed_at");
    public Task<List<long>> OwnerIds(long listing)=>ReadOwners(listing);
    private async Task<List<long>> ReadOwners(long listing)
    {
        await using var cmd=Command("SELECT o.client_id FROM estate.v_property_owners o JOIN estate.v_active_listings l ON l.property_id=o.property_id WHERE l.id=$1 ORDER BY o.client_id",listing);
        await using var r=await cmd.ExecuteReaderAsync(); var ids=new List<long>();
        while(await r.ReadAsync()) ids.Add(r.GetInt64(0)); return ids;
    }
}
public sealed class PaymentRepository(NpgsqlConnection c,NpgsqlTransaction t):Repository(c,t)
{
    public Task Add(Guid contract,decimal amount,long actor)=>Execute("CALL estate.add_payment($1,$2,$3)",contract,amount,actor);
}
public sealed class ReportRepository(NpgsqlConnection c,NpgsqlTransaction t):Repository(c,t)
{
    public Task<List<string[]>> Users()=>Query("SELECT * FROM estate.v_users ORDER BY id");
    public Task<List<string[]>> Types()=>Query("SELECT * FROM estate.v_property_types ORDER BY id");
    public Task<List<string[]>> Audit()=>Query("SELECT id,table_name,record_id,operation,changed_at,changed_by FROM estate.v_audit ORDER BY id DESC LIMIT 30");
    public Task<List<string[]>> Prices()=>Query("SELECT * FROM estate.v_price_history ORDER BY id");
    public Task<List<string[]>> Payments()=>Query("SELECT * FROM estate.v_payments ORDER BY id");
    public Task<List<string[]>> Participants()=>Query("SELECT * FROM estate.v_participants ORDER BY contract_id,client_id");
    public Task<List<string[]>> Viewings()=>Query("SELECT * FROM estate.v_viewings ORDER BY starts_at");
    public Task<List<string[]>> Offers()=>Query("SELECT * FROM estate.v_offers ORDER BY id");
}
