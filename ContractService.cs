namespace RealEstate;

public sealed class ContractService(string connectionString)
{
    // This is the business transaction across four logical entities.
    public async Task<Guid> SignAsync(long listing,long customer,decimal amount,decimal deposit,long actor,bool failDemo=false)
    {
        if(deposit<0 || deposit>amount) throw new ArgumentException("Початковий платіж має бути від 0 до суми договору.");
        await using var uow=await UnitOfWork.OpenAsync(connectionString);
        var id=Guid.NewGuid();
        await uow.Contracts.Create(id,listing,amount,actor);
        var owners=await uow.Contracts.OwnerIds(listing);
        if(owners.Count==0) throw new InvalidOperationException("Власників не знайдено.");
        foreach(var owner in owners) await uow.Contracts.Participant(id,owner,"owner",actor);
        await uow.Contracts.Participant(id,customer,"customer",actor);
        if(deposit>0) await uow.Payments.Add(id,deposit,actor);
        await uow.Listings.Close(listing,actor);
        // Fail AFTER all valid changes; the database rejects a negative payment.
        if(failDemo) await uow.Payments.Add(id,-1m,actor);
        await uow.CommitAsync();
        return id;
        // On an exception await using disposes the UoW, which rolls everything back.
    }
}
