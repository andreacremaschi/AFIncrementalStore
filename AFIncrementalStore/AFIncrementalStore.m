// AFIncrementalStore.m
//
// Copyright (c) 2012 Mattt Thompson (http://mattt.me)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "AFIncrementalStore.h"
#import "AFHTTPClient.h"
#import <objc/runtime.h>

NSString * const AFIncrementalStoreUnimplementedMethodException = @"com.alamofire.incremental-store.exceptions.unimplemented-method";
NSString * const AFIncrementalStoreErrorDomain = @"AFIncrementalStoreErrorDomain";

NSString * const AFIncrementalStoreContextWillFetchRemoteValues = @"AFIncrementalStoreContextWillFetchRemoteValues";
NSString * const AFIncrementalStoreContextWillSaveRemoteValues = @"AFIncrementalStoreContextWillSaveRemoteValues";
NSString * const AFIncrementalStoreContextDidFetchRemoteValues = @"AFIncrementalStoreContextDidFetchRemoteValues";
NSString * const AFIncrementalStoreContextDidSaveRemoteValues = @"AFIncrementalStoreContextDidSaveRemoteValues";
NSString * const AFIncrementalStoreContextWillFetchNewValuesForObject = @"AFIncrementalStoreContextWillFetchNewValuesForObject";
NSString * const AFIncrementalStoreContextDidFetchNewValuesForObject = @"AFIncrementalStoreContextDidFetchNewValuesForObject";
NSString * const AFIncrementalStoreContextWillFetchNewValuesForRelationship = @"AFIncrementalStoreContextWillFetchNewValuesForRelationship";
NSString * const AFIncrementalStoreContextDidFetchNewValuesForRelationship = @"AFIncrementalStoreContextDidFetchNewValuesForRelationship";

NSString * const AFIncrementalStoreRequestOperationsKey = @"AFIncrementalStoreRequestOperations";
NSString * const AFIncrementalStoreFetchedObjectIDsKey = @"AFIncrementalStoreFetchedObjectIDs";
NSString * const AFIncrementalStoreFaultingObjectIDKey = @"AFIncrementalStoreFaultingObjectID";
NSString * const AFIncrementalStoreFaultingRelationshipKey = @"AFIncrementalStoreFaultingRelationship";
NSString * const AFIncrementalStorePersistentStoreRequestKey = @"AFIncrementalStorePersistentStoreRequest";

static char kAFResourceIdentifierObjectKey;

static NSString * const kAFIncrementalStoreResourceIdentifierAttributeName = @"__af_resourceIdentifier";
static NSString * const kAFIncrementalStoreLastModifiedAttributeName = @"__af_lastModified";

static NSString * const kAFReferenceObjectPrefix = @"__af_";

inline NSString * AFReferenceObjectFromResourceIdentifier(NSString *resourceIdentifier) {
    if (!resourceIdentifier) {
        return nil;
    }
    
    return [kAFReferenceObjectPrefix stringByAppendingString:resourceIdentifier];    
}

inline NSString * AFResourceIdentifierFromReferenceObject(id referenceObject) {
    if (!referenceObject) {
        return nil;
    }
    
    NSString *string = [referenceObject description];
    return [string hasPrefix:kAFReferenceObjectPrefix] ? [string substringFromIndex:[kAFReferenceObjectPrefix length]] : string;
}

inline NSString * AFResourceIdentifierFromReferenceObjectID(NSManagedObjectID *objectID) {
    if (!objectID) {
        return nil;
    }
    
    NSString *string = [[[objectID URIRepresentation] lastPathComponent] substringFromIndex:1];
    return [string hasPrefix:kAFReferenceObjectPrefix] ? [string substringFromIndex:[kAFReferenceObjectPrefix length] + 1] : string;
}

static inline void AFSaveManagedObjectContextOrThrowInternalConsistencyException(NSManagedObjectContext *managedObjectContext) {
    NSError *error = nil;
    if (![managedObjectContext save:&error]) {
        @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:[error localizedFailureReason] userInfo:[NSDictionary dictionaryWithObject:error forKey:NSUnderlyingErrorKey]];
    }
}

@interface NSManagedObject (_AFIncrementalStore)
@property (readwrite, nonatomic, copy, setter = af_setResourceIdentifier:) NSString *af_resourceIdentifier;
@end

@implementation NSManagedObject (_AFIncrementalStore)
@dynamic af_resourceIdentifier;

- (NSString *)af_resourceIdentifier {
    NSString *identifier = (NSString *)objc_getAssociatedObject(self, &kAFResourceIdentifierObjectKey);
    
    if (!identifier) {
        if ([self.objectID.persistentStore isKindOfClass:[AFIncrementalStore class]]) {
            id referenceObject = [(AFIncrementalStore *)self.objectID.persistentStore referenceObjectForObjectID:self.objectID];
            if ([referenceObject isKindOfClass:[NSString class]]) {
                return AFResourceIdentifierFromReferenceObject(referenceObject);
            }
        }
    }
    
    return identifier;
}

- (void)af_setResourceIdentifier:(NSString *)resourceIdentifier {
    objc_setAssociatedObject(self, &kAFResourceIdentifierObjectKey, resourceIdentifier, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

@end

#pragma mark -

@implementation AFIncrementalStore {
@private
    NSCache *_backingObjectIDByObjectID;
    NSMutableDictionary *_registeredObjectIDsByEntityNameAndNestedResourceIdentifier;
    NSPersistentStoreCoordinator *_backingPersistentStoreCoordinator;
    NSMutableDictionary * _rowCache;

}
@synthesize HTTPClient = _HTTPClient;
@synthesize backingPersistentStoreCoordinator = _backingPersistentStoreCoordinator;

+ (NSString *)type {
    @throw([NSException exceptionWithName:AFIncrementalStoreUnimplementedMethodException reason:NSLocalizedString(@"Unimplemented method: +type. Must be overridden in a subclass", nil) userInfo:nil]);
}

+ (NSManagedObjectModel *)model {
    @throw([NSException exceptionWithName:AFIncrementalStoreUnimplementedMethodException reason:NSLocalizedString(@"Unimplemented method: +model. Must be overridden in a subclass", nil) userInfo:nil]);
}

#pragma mark -

- (id)executeFetchRequest:(NSFetchRequest *)fetchRequest
              withContext:(NSManagedObjectContext *)context
                    error:(NSError *__autoreleasing *)error
{
	NSFetchRequest *backingFetchRequest = [fetchRequest copy];
	backingFetchRequest.entity = [NSEntityDescription entityForName:fetchRequest.entityName inManagedObjectContext:context];
   
    NSArray *objectIDs = [self fetchObjectIDs:fetchRequest withContext:context error:error];
    
    switch (fetchRequest.resultType) {
            
        case NSManagedObjectResultType: {

            NSMutableArray *array = [NSMutableArray arrayWithCapacity:objectIDs.count];
            for (id objectID in objectIDs) {
                NSManagedObject *managedObject = [context objectWithID: objectID];
                [array addObject:managedObject];
            }
            
            return [array copy];
        }
            
        case NSManagedObjectIDResultType: {
            
            return objectIDs;
        }
        case NSDictionaryResultType:
        case NSCountResultType:

        default:
            return nil;
    }
}

- (id)executeSaveChangesRequest:(NSSaveChangesRequest *)saveChangesRequest
                    withContext:(NSManagedObjectContext *)context
                          error:(NSError *__autoreleasing *)error
{

    NSSet *insertedObjects = [saveChangesRequest insertedObjects];
    NSSet *updatedObjects = [saveChangesRequest updatedObjects];
    NSSet *deletedObjects = [saveChangesRequest deletedObjects];
    NSSet *optLockObjects = [saveChangesRequest lockedObjects];

    NSMutableArray *URLRequests = [NSMutableArray array];
    
 /*   if ([self.HTTPClient respondsToSelector:@selector(requestForInsertedObject:)]) {
        for (NSManagedObject *insertedObject in [saveChangesRequest insertedObjects]) {
            NSURLRequest *request = [self.HTTPClient requestForInsertedObject:insertedObject];
            if (!request) {
                [backingContext performBlockAndWait:^{
                    CFUUIDRef UUID = CFUUIDCreate(NULL);
                    NSString *resourceIdentifier = (__bridge_transfer NSString *)CFUUIDCreateString(NULL, UUID);
                    CFRelease(UUID);
                    
                    NSManagedObject *backingObject = [NSEntityDescription insertNewObjectForEntityForName:insertedObject.entity.name inManagedObjectContext:backingContext];
                    [backingObject.managedObjectContext obtainPermanentIDsForObjects:[NSArray arrayWithObject:backingObject] error:nil];
                    [backingObject setValue:resourceIdentifier forKey:kAFIncrementalStoreResourceIdentifierAttributeName];
                    [self updateBackingObject:backingObject withAttributeAndRelationshipValuesFromManagedObject:insertedObject];
                    [backingContext save:nil];
                }];
                
                [insertedObject willChangeValueForKey:@"objectID"];
                [context obtainPermanentIDsForObjects:[NSArray arrayWithObject:insertedObject] error:nil];
                [insertedObject didChangeValueForKey:@"objectID"];
                continue;
            }
            
            AFHTTPRequestOperation *operation = [self.HTTPClient HTTPRequestOperationWithRequest:request success:^(AFHTTPRequestOperation *operation, id responseObject) {
                id representationOrArrayOfRepresentations = [self.HTTPClient representationOrArrayOfRepresentationsOfEntity:[insertedObject entity]  fromResponseObject:responseObject];
                if ([representationOrArrayOfRepresentations isKindOfClass:[NSDictionary class]]) {
                    NSDictionary *representation = (NSDictionary *)representationOrArrayOfRepresentations;

                    NSString *resourceIdentifier = [self.HTTPClient resourceIdentifierForRepresentation:representation ofEntity:[insertedObject entity] fromResponse:operation.response];
                    NSManagedObjectID *backingObjectID = [self objectIDForBackingObjectForEntity:[insertedObject entity] withResourceIdentifier:resourceIdentifier];
                    insertedObject.af_resourceIdentifier = resourceIdentifier;
                    [insertedObject setValuesForKeysWithDictionary:[self.HTTPClient attributesForRepresentation:representation ofEntity:insertedObject.entity fromResponse:operation.response]];

                    [backingContext performBlockAndWait:^{
                        __block NSManagedObject *backingObject = nil;
                        if (backingObjectID) {
                            [backingContext performBlockAndWait:^{
                                backingObject = [backingContext existingObjectWithID:backingObjectID error:nil];
                            }];
                        }

                        if (!backingObject) {
                            backingObject = [NSEntityDescription insertNewObjectForEntityForName:insertedObject.entity.name inManagedObjectContext:backingContext];
                            [backingObject.managedObjectContext obtainPermanentIDsForObjects:[NSArray arrayWithObject:backingObject] error:nil];
                        }

                        [backingObject setValue:resourceIdentifier forKey:kAFIncrementalStoreResourceIdentifierAttributeName];
                        [self updateBackingObject:backingObject withAttributeAndRelationshipValuesFromManagedObject:insertedObject];
                        [backingContext save:nil];
                    }];

                    [insertedObject willChangeValueForKey:@"objectID"];
                    [context obtainPermanentIDsForObjects:[NSArray arrayWithObject:insertedObject] error:nil];
                    [insertedObject didChangeValueForKey:@"objectID"];

                    [context refreshObject:insertedObject mergeChanges:NO];
                }
            } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
				 NSLog(@"Insert Error: %@", error);
				
				// Reset destination objects to prevent dangling relationships
				for (NSRelationshipDescription *relationship in [insertedObject.entity.relationshipsByName allValues]) {
					if (!relationship.inverseRelationship) {
						continue;
					}

                    id <NSFastEnumeration> destinationObjects = nil;
					if ([relationship isToMany]) {
						destinationObjects = [insertedObject valueForKey:relationship.name];
					} else {
						NSManagedObject *destinationObject = [insertedObject valueForKey:relationship.name];
						if (destinationObject) {
							destinationObjects = [NSArray arrayWithObject:destinationObject];
						}
					}
					
					for (NSManagedObject *destinationObject in destinationObjects) {
						[context refreshObject:destinationObject mergeChanges:NO];
					}
				}
            }];
            
            [mutableOperations addObject:operation];
        }
    }
    */

    if ([self.HTTPClient respondsToSelector:@selector(requestForInsertedObject:)]) {
        
        for (NSManagedObject *insertedObject in insertedObjects) {
            
            NSURLRequest *request = [self.HTTPClient requestForUpdatedObject: insertedObject];
            if (request)
                [URLRequests addObject: request];
        }
    }
    
    if ([self.HTTPClient respondsToSelector:@selector(requestForUpdatedObject:)]) {
        
        for (NSManagedObject *updatedObject in updatedObjects) {

            NSURLRequest *request = [self.HTTPClient requestForUpdatedObject:updatedObject];
            if (request)
                [URLRequests addObject: request];
        }
    }
    
    if ([self.HTTPClient respondsToSelector:@selector(requestForDeletedObject:)]) {
        for (NSManagedObject *deletedObject in deletedObjects) {
            
            NSURLRequest *request = [self.HTTPClient requestForDeletedObject:deletedObject];
            if (request)
                [URLRequests addObject: request];
        }
    }
    
    
    [URLRequests enumerateObjectsUsingBlock: ^(NSURLRequest* URLrequest, NSUInteger idx, BOOL *stop) {
        NSURLResponse *response;
        NSError *requestError;

        NSData *responseData = [NSURLConnection sendSynchronousRequest:URLrequest returningResponse:&response error:&requestError];
        
        if (requestError) {
            *error = requestError;
            *stop = YES;
        } else {
            
            NSError *resultError;
            
            BOOL result = YES;
            if ([self.HTTPClient respondsToSelector:@selector(parseCRUDOperationResult:request:response:error:)])
                result = [self.HTTPClient parseCRUDOperationResult: responseData
                                                           request: URLrequest
                                                          response: response
                                                             error: &resultError];
            if (!result) {
                *error = resultError;
                *stop = YES;
            }
        }
 
    }];
    
    return [NSArray array];
}

- (NSArray *) arrayOfObjectIDsFromResponse: (id)responseObject entity: (NSEntityDescription *)entity {
    NSArray* representations;
    id representationOrArrayOfRepresentations = [self.HTTPClient representationOrArrayOfRepresentationsOfEntity:entity fromResponseObject:responseObject];
    if ([representationOrArrayOfRepresentations isKindOfClass:[NSArray class]]) {
        representations = representationOrArrayOfRepresentations;
    } else if ([representationOrArrayOfRepresentations isKindOfClass:[NSDictionary class]]) {
        representations = [NSArray arrayWithObject:representationOrArrayOfRepresentations];
    }
    
    NSMutableArray *keysArray = [NSMutableArray arrayWithCapacity: representations.count];
    for (NSDictionary *representation in representations) {
        NSString *resourceIdentifier = [self.HTTPClient resourceIdentifierForRepresentation:representation ofEntity:entity fromResponse:responseObject];
        NSDictionary *attributes = [self.HTTPClient attributesForRepresentation:representation ofEntity:entity fromResponse:responseObject];

        NSManagedObjectID *objectID = [self newObjectIDForEntity: entity referenceObject:resourceIdentifier];
        [keysArray addObject:objectID];
        [_rowCache setObject:attributes forKey: objectID];

    }
    
    return [keysArray copy];
}

// Returns NSArray<NSManagedObjectID>

- (id)fetchObjectIDs:(NSFetchRequest *)fetchRequest withContext:(NSManagedObjectContext *)context error:(NSError *__autoreleasing *)error {
    
    NSURLRequest *request = [self.HTTPClient requestForFetchRequest:fetchRequest withContext:context];
    if ([request URL]) {
        
        NSURLResponse *response;
        NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:error];
        id responseObject = [NSJSONSerialization JSONObjectWithData: data
                                                            options: kNilOptions
                                                              error: error];
        NSArray *objectIDs = [self arrayOfObjectIDsFromResponse:responseObject entity:fetchRequest.entity];
        
        return objectIDs;
    }
    
    return nil;
}

#pragma mark - NSIncrementalStore

- (BOOL)loadMetadata:(NSError *__autoreleasing *)error {
    if (!_backingObjectIDByObjectID) {
        NSMutableDictionary *mutableMetadata = [NSMutableDictionary dictionary];
        [mutableMetadata setValue:[[NSProcessInfo processInfo] globallyUniqueString] forKey:NSStoreUUIDKey];
        [mutableMetadata setValue:NSStringFromClass([self class]) forKey:NSStoreTypeKey];
        [self setMetadata:mutableMetadata];
        
        _backingObjectIDByObjectID = [[NSCache alloc] init];
        _registeredObjectIDsByEntityNameAndNestedResourceIdentifier = [[NSMutableDictionary alloc] init];
        
        NSManagedObjectModel *model = [self.persistentStoreCoordinator.managedObjectModel copy];
        for (NSEntityDescription *entity in model.entities) {
            // Don't add properties for sub-entities, as they already exist in the super-entity
            if ([entity superentity]) {
                continue;
            }
            
            NSAttributeDescription *resourceIdentifierProperty = [[NSAttributeDescription alloc] init];
            [resourceIdentifierProperty setName:kAFIncrementalStoreResourceIdentifierAttributeName];
            [resourceIdentifierProperty setAttributeType:NSStringAttributeType];
            [resourceIdentifierProperty setIndexed:YES];
            
            NSAttributeDescription *lastModifiedProperty = [[NSAttributeDescription alloc] init];
            [lastModifiedProperty setName:kAFIncrementalStoreLastModifiedAttributeName];
            [lastModifiedProperty setAttributeType:NSStringAttributeType];
            [lastModifiedProperty setIndexed:NO];
            
            [entity setProperties:[entity.properties arrayByAddingObjectsFromArray:[NSArray arrayWithObjects:resourceIdentifierProperty, lastModifiedProperty, nil]]];
        }
        
        _backingPersistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
        _rowCache = [NSMutableDictionary dictionary];
        
        return YES;
    } else {
        return NO;
    }
}

- (NSArray *)obtainPermanentIDsForObjects:(NSArray *)array error:(NSError **)error {
    NSMutableArray *mutablePermanentIDs = [NSMutableArray arrayWithCapacity:[array count]];
    for (NSManagedObject *managedObject in array) {
        NSURLRequest *request = [self.HTTPClient requestForInsertedObject: managedObject];
        if ([request URL]) {
            NSURLResponse *response;
            NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:error];
            NSDictionary *responseObject = [NSJSONSerialization JSONObjectWithData: data
                                                                options: kNilOptions
                                                                  error: error];

            // TODO refactor in AFIncrementalStore protocol
            if ([responseObject.allKeys containsObject: @"objectId"]) {
                NSString *resourceIdentifier = responseObject[@"objectId"];
//                NSURL *locationURL = [NSURL URLWithString:location];
                NSManagedObjectID *objectID = [self newObjectIDForEntity:managedObject.entity referenceObject:resourceIdentifier];
                [mutablePermanentIDs addObject:objectID];
            } else {
                // TODO: error handling
            }

        }

    }
    
    return mutablePermanentIDs;

}

- (id)executeRequest:(NSPersistentStoreRequest *)persistentStoreRequest
         withContext:(NSManagedObjectContext *)context
               error:(NSError *__autoreleasing *)error
{
    if (persistentStoreRequest.requestType == NSFetchRequestType) {
        return [self executeFetchRequest:(NSFetchRequest *)persistentStoreRequest withContext:context error:error];
    } else if (persistentStoreRequest.requestType == NSSaveRequestType) {
        return [self executeSaveChangesRequest:(NSSaveChangesRequest *)persistentStoreRequest withContext:context error:error];
    } else {
        NSMutableDictionary *mutableUserInfo = [NSMutableDictionary dictionary];
        [mutableUserInfo setValue:[NSString stringWithFormat:NSLocalizedString(@"Unsupported NSFetchRequestResultType, %d", nil), persistentStoreRequest.requestType] forKey:NSLocalizedDescriptionKey];
        if (error) {
            *error = [[NSError alloc] initWithDomain:AFNetworkingErrorDomain code:0 userInfo:mutableUserInfo];
        }
        
        return nil;
    }
}

- (NSIncrementalStoreNode *)newValuesForObjectWithID:(NSManagedObjectID *)objectID
                                         withContext:(NSManagedObjectContext *)context
                                               error:(NSError *__autoreleasing *)error
{
//    NSString *uniqueIdentifier = AFResourceIdentifierFromReferenceObjectID( objectID );
    NSIncrementalStoreNode *node;
    
    NSDictionary *attributes = [_rowCache objectForKey: objectID];
    if (attributes) [_rowCache removeObjectForKey: objectID];
    
    if (!attributes) {
        NSMutableURLRequest *request = [self.HTTPClient requestWithMethod:@"GET" pathForObjectWithID:objectID withContext:context];
        if ([request URL]) {
            
            NSURLResponse *response;
            NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:error];
            id responseObject = [NSJSONSerialization JSONObjectWithData: data
                                                                options: kNilOptions
                                                                  error: error];
            
            // TODO: check for errors
            if ([responseObject isKindOfClass:[NSDictionary class]])
                attributes = responseObject;
            
        }
    }
    
    if (attributes) {
        
        // remove relationships representation from the object representation
        NSEntityDescription *entity = objectID.entity;
        NSDictionary *relationshipsByName = [entity relationshipsByName];
        NSArray *relationshipsNames = relationshipsByName.allKeys;
        if (relationshipsNames.count>0) {
            
            NSMutableDictionary *dict = [attributes mutableCopy];
            for (id relationshipName in relationshipsNames) {
                
                NSRelationshipDescription *relationship= relationshipsByName[relationshipName];
                if ([relationship isToMany]) {
                    [dict removeObjectForKey:relationshipName];
                } else {
                    // to-1
                    id relationshipRepresentation = dict[relationshipName];
                    
                    NSEntityDescription *destinationEntity = relationship.destinationEntity;
                    NSString *resourceIdentifier = [self.HTTPClient resourceIdentifierForRepresentation: relationshipRepresentation
                                                                                               ofEntity: destinationEntity
                                                                                           fromResponse: nil];
                    NSManagedObjectID *objectID = [self newObjectIDForEntity: destinationEntity referenceObject:resourceIdentifier];
                    [dict setObject:objectID forKey: relationshipName];
                    
                }
                
            }
            attributes = dict;
        }
        
        
        node = [[NSIncrementalStoreNode alloc] initWithObjectID:objectID withValues:attributes version:1];
    }
    
    return node;
}

- (id)newValueForRelationship:(NSRelationshipDescription *)relationship
              forObjectWithID:(NSManagedObjectID *)objectID
                  withContext:(NSManagedObjectContext *)context
                        error:(NSError *__autoreleasing *)error
{

    NSURLRequest *request = [self.HTTPClient requestWithMethod:@"GET" pathForRelationship:relationship forObjectWithID:objectID withContext:context];
    if ([request URL]) {
        
        NSURLResponse *response;
        NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:error];
        id responseObject = [NSJSONSerialization JSONObjectWithData: data
                                                            options: kNilOptions
                                                              error: error];
        
        NSArray *objectIDs = [self arrayOfObjectIDsFromResponse:responseObject entity: relationship.destinationEntity];

        return objectIDs;
    }
    
    return nil;
    
}


@end
