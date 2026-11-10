const database = db.getSiblingDB('RealEstateNoSql');
const collection = database.properties;
collection.drop();

const names = ['Apartment', 'House', 'Commercial'];
const batchSize = 1000;

for (let start = 1; start <= 100000; start += batchSize) {
    const batch = [];
    for (let i = start; i < Math.min(start + batchSize, 100001); i++) {
        batch.push({
            property_id: i,
            type_name: names[i % 3],
            address: `Address ${i}`,
            area: 30 + (i % 200),
            description: `Property description ${i}`,
            photos: Array.from({length: 5}, (_, j) => ({
                url: `https://example.com/photos/${i}/${j + 1}.jpg`
            })),
            amenities: Array.from({length: 6}, (_, j) => `Amenity ${j + 1}`)
        });
    }
    collection.insertMany(batch);
}

collection.createIndex({ property_id: 1 }, { unique: true });
collection.createIndex({ type_name: 1, area: 1 });

print(`Properties: ${collection.countDocuments({})}`);
print('Example document:');
printjson(collection.findOne({ property_id: 50000 }));

// Examples equivalent to SQL queries used for benchmarking:
print('Read 50:', collection.find({ property_id: { $gte: 50000, $lte: 50049 } })
    .sort({ property_id: 1 }).toArray().length);
print('Filter 50:', collection.find({ type_name: 'Apartment', area: { $gte: 50, $lte: 100 } })
    .sort({ property_id: 1 }).limit(50).toArray().length);

