/*
 * Copyright 2017 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "Firestore/Source/Local/FSTLocalStore.h"

#import <FirebaseFirestore/FIRTimestamp.h>
#import <XCTest/XCTest.h>

#import "Firestore/Source/Core/FSTQuery.h"
#import "Firestore/Source/Local/FSTEagerGarbageCollector.h"
#import "Firestore/Source/Local/FSTLocalWriteResult.h"
#import "Firestore/Source/Local/FSTNoOpGarbageCollector.h"
#import "Firestore/Source/Local/FSTPersistence.h"
#import "Firestore/Source/Local/FSTQueryCache.h"
#import "Firestore/Source/Local/FSTQueryData.h"
#import "Firestore/Source/Model/FSTDocument.h"
#import "Firestore/Source/Model/FSTDocumentKey.h"
#import "Firestore/Source/Model/FSTDocumentSet.h"
#import "Firestore/Source/Model/FSTMutation.h"
#import "Firestore/Source/Model/FSTMutationBatch.h"
#import "Firestore/Source/Remote/FSTRemoteEvent.h"
#import "Firestore/Source/Remote/FSTWatchChange.h"
#import "Firestore/Source/Util/FSTClasses.h"

#import "Firestore/Example/Tests/Local/FSTLocalStoreTests.h"
#import "Firestore/Example/Tests/Remote/FSTWatchChange+Testing.h"
#import "Firestore/Example/Tests/Util/FSTHelpers.h"
#import "Firestore/third_party/Immutable/Tests/FSTImmutableSortedDictionary+Testing.h"
#import "Firestore/third_party/Immutable/Tests/FSTImmutableSortedSet+Testing.h"

#include "Firestore/core/src/firebase/firestore/auth/user.h"

using firebase::firestore::auth::User;

NS_ASSUME_NONNULL_BEGIN

@interface FSTLocalStoreTests ()

@property(nonatomic, strong, readwrite) id<FSTPersistence> localStorePersistence;
@property(nonatomic, strong, readwrite) FSTLocalStore *localStore;

@property(nonatomic, strong, readonly) NSMutableArray<FSTMutationBatch *> *batches;
@property(nonatomic, strong, readwrite, nullable) FSTMaybeDocumentDictionary *lastChanges;
@property(nonatomic, assign, readwrite) FSTTargetID lastTargetID;

@end

@implementation FSTLocalStoreTests

- (void)setUp {
  [super setUp];

  if ([self isTestBaseClass]) {
    return;
  }

  id<FSTPersistence> persistence = [self persistence];
  self.localStorePersistence = persistence;
  id<FSTGarbageCollector> garbageCollector = [[FSTEagerGarbageCollector alloc] init];
  self.localStore = [[FSTLocalStore alloc] initWithPersistence:persistence
                                              garbageCollector:garbageCollector
                                                   initialUser:User::Unauthenticated()];
  [self.localStore start];

  _batches = [NSMutableArray array];
  _lastChanges = nil;
  _lastTargetID = 0;
}

- (void)tearDown {
  [self.localStorePersistence shutdown];

  [super tearDown];
}

- (id<FSTPersistence>)persistence {
  @throw FSTAbstractMethodException();  // NOLINT
}

- (BOOL)gcIsEager {
  @throw FSTAbstractMethodException();  // NOLINT
}

/**
 * Xcode will run tests from any class that extends XCTestCase, but this doesn't work for
 * FSTLocalStoreTests since it is incomplete without the implementations supplied by its
 * subclasses.
 */
- (BOOL)isTestBaseClass {
  return [self class] == [FSTLocalStoreTests class];
}

- (void)writeMutation:(FSTMutation *)mutation {
  [self writeMutations:@[ mutation ]];
}

- (void)writeMutations:(NSArray<FSTMutation *> *)mutations {
  FSTLocalWriteResult *result = [self.localStore locallyWriteMutations:mutations];
  XCTAssertNotNil(result);
  [self.batches addObject:[[FSTMutationBatch alloc] initWithBatchID:result.batchID
                                                     localWriteTime:[FIRTimestamp timestamp]
                                                          mutations:mutations]];
  self.lastChanges = result.changes;
}

- (void)applyRemoteEvent:(FSTRemoteEvent *)event {
  self.lastChanges = [self.localStore applyRemoteEvent:event];
}

- (void)notifyLocalViewChanges:(FSTLocalViewChanges *)changes {
  [self.localStore notifyLocalViewChanges:@[ changes ]];
}

- (void)acknowledgeMutationWithVersion:(FSTTestSnapshotVersion)documentVersion {
  FSTMutationBatch *batch = [self.batches firstObject];
  [self.batches removeObjectAtIndex:0];
  XCTAssertEqual(batch.mutations.count, 1, @"Acknowledging more than one mutation not supported.");
  FSTSnapshotVersion *version = FSTTestVersion(documentVersion);
  FSTMutationResult *mutationResult =
      [[FSTMutationResult alloc] initWithVersion:version transformResults:nil];
  FSTMutationBatchResult *result = [FSTMutationBatchResult resultWithBatch:batch
                                                             commitVersion:version
                                                           mutationResults:@[ mutationResult ]
                                                               streamToken:nil];
  self.lastChanges = [self.localStore acknowledgeBatchWithResult:result];
}

- (void)rejectMutation {
  FSTMutationBatch *batch = [self.batches firstObject];
  [self.batches removeObjectAtIndex:0];
  self.lastChanges = [self.localStore rejectBatchID:batch.batchID];
}

- (FSTTargetID)allocateQuery:(FSTQuery *)query {
  FSTQueryData *queryData = [self.localStore allocateQuery:query];
  self.lastTargetID = queryData.targetID;
  return queryData.targetID;
}

- (void)collectGarbage {
  return;
}

/** Asserts that the last target ID is the given number. */
#define FSTAssertTargetID(targetID)              \
  do {                                           \
    XCTAssertEqual(self.lastTargetID, targetID); \
  } while (0)

/** Asserts that a the lastChanges contain the docs in the given array. */
#define FSTAssertChanged(documents)                                                             \
  XCTAssertNotNil(self.lastChanges);                                                            \
  do {                                                                                          \
    FSTMaybeDocumentDictionary *actual = self.lastChanges;                                      \
    NSArray<FSTMaybeDocument *> *expected = (documents);                                        \
    XCTAssertEqual(actual.count, expected.count);                                               \
    NSEnumerator<FSTMaybeDocument *> *enumerator = expected.objectEnumerator;                   \
    [actual enumerateKeysAndObjectsUsingBlock:^(FSTDocumentKey * key, FSTMaybeDocument * value, \
                                                BOOL * stop) {                                  \
      XCTAssertEqualObjects(value, [enumerator nextObject]);                                    \
    }];                                                                                         \
    self.lastChanges = nil;                                                                     \
  } while (0)

/** Asserts that the given keys were removed. */
#define FSTAssertRemoved(keyPaths)                                                       \
  XCTAssertNotNil(self.lastChanges);                                                     \
  do {                                                                                   \
    FSTMaybeDocumentDictionary *actual = self.lastChanges;                               \
    XCTAssertEqual(actual.count, keyPaths.count);                                        \
    NSEnumerator<NSString *> *keyPathEnumerator = keyPaths.objectEnumerator;             \
    [actual enumerateKeysAndObjectsUsingBlock:^(FSTDocumentKey * actualKey,              \
                                                FSTMaybeDocument * value, BOOL * stop) { \
      FSTDocumentKey *expectedKey = FSTTestDocKey([keyPathEnumerator nextObject]);       \
      XCTAssertEqualObjects(actualKey, expectedKey);                                     \
      XCTAssertTrue([value isKindOfClass:[FSTDeletedDocument class]]);                   \
    }];                                                                                  \
    self.lastChanges = nil;                                                              \
  } while (0)

/** Asserts that the given local store contains the given document. */
#define FSTAssertContains(document)                                         \
  do {                                                                      \
    FSTMaybeDocument *expected = (document);                                \
    FSTMaybeDocument *actual = [self.localStore readDocument:expected.key]; \
    XCTAssertEqualObjects(actual, expected);                                \
  } while (0)

/** Asserts that the given local store does not contain the given document. */
#define FSTAssertNotContains(keyPathString)                        \
  do {                                                             \
    FSTDocumentKey *key = FSTTestDocKey(keyPathString);            \
    FSTMaybeDocument *actual = [self.localStore readDocument:key]; \
    XCTAssertNil(actual);                                          \
  } while (0)

- (void)testMutationBatchKeys {
  if ([self isTestBaseClass]) return;

  FSTMutation *set1 = FSTTestSetMutation(@"foo/bar", @{@"foo" : @"bar"});
  FSTMutation *set2 = FSTTestSetMutation(@"bar/baz", @{@"bar" : @"baz"});
  FSTMutationBatch *batch = [[FSTMutationBatch alloc] initWithBatchID:1
                                                       localWriteTime:[FIRTimestamp timestamp]
                                                            mutations:@[ set1, set2 ]];
  FSTDocumentKeySet *keys = [batch keys];
  XCTAssertEqual(keys.count, 2);
}

- (void)testHandlesSetMutation {
  if ([self isTestBaseClass]) return;

  [self writeMutation:FSTTestSetMutation(@"foo/bar", @{@"foo" : @"bar"})];
  FSTAssertChanged(@[ FSTTestDoc("foo/bar", 0, @{@"foo" : @"bar"}, YES) ]);
  FSTAssertContains(FSTTestDoc("foo/bar", 0, @{@"foo" : @"bar"}, YES));

  [self acknowledgeMutationWithVersion:0];
  FSTAssertChanged(@[ FSTTestDoc("foo/bar", 0, @{@"foo" : @"bar"}, NO) ]);
  if ([self gcIsEager]) {
    // Nothing is pinning this anymore, as it has been acknowledged and there are no targets active.
    FSTAssertNotContains(@"foo/bar");
  }
}

- (void)testHandlesSetMutationThenDocument {
  if ([self isTestBaseClass]) return;

  [self writeMutation:FSTTestSetMutation(@"foo/bar", @{@"foo" : @"bar"})];
  FSTAssertChanged(@[ FSTTestDoc("foo/bar", 0, @{@"foo" : @"bar"}, YES) ]);
  FSTAssertContains(FSTTestDoc("foo/bar", 0, @{@"foo" : @"bar"}, YES));

  [self applyRemoteEvent:FSTTestUpdateRemoteEvent(
                             FSTTestDoc("foo/bar", 2, @{@"it" : @"changed"}, NO), @[ @1 ], @[])];
  FSTAssertChanged(@[ FSTTestDoc("foo/bar", 2, @{@"foo" : @"bar"}, YES) ]);
  FSTAssertContains(FSTTestDoc("foo/bar", 2, @{@"foo" : @"bar"}, YES));
}

- (void)testHandlesAckThenRejectThenRemoteEvent {
  if ([self isTestBaseClass]) return;

  // Start a query that requires acks to be held.
  FSTQuery *query = FSTTestQuery("foo");
  FSTTargetID targetID = [self allocateQuery:query];

  [self writeMutation:FSTTestSetMutation(@"foo/bar", @{@"foo" : @"bar"})];
  FSTAssertChanged(@[ FSTTestDoc("foo/bar", 0, @{@"foo" : @"bar"}, YES) ]);
  FSTAssertContains(FSTTestDoc("foo/bar", 0, @{@"foo" : @"bar"}, YES));

  // The last seen version is zero, so this ack must be held.
  [self acknowledgeMutationWithVersion:1];
  FSTAssertChanged(@[]);
  FSTAssertContains(FSTTestDoc("foo/bar", 0, @{@"foo" : @"bar"}, YES));

  [self writeMutation:FSTTestSetMutation(@"bar/baz", @{@"bar" : @"baz"})];
  FSTAssertChanged(@[ FSTTestDoc("bar/baz", 0, @{@"bar" : @"baz"}, YES) ]);
  FSTAssertContains(FSTTestDoc("bar/baz", 0, @{@"bar" : @"baz"}, YES));

  [self rejectMutation];
  FSTAssertRemoved(@[ @"bar/baz" ]);
  FSTAssertNotContains(@"bar/baz");

  [self applyRemoteEvent:FSTTestUpdateRemoteEvent(
                             FSTTestDoc("foo/bar", 2, @{@"it" : @"changed"}, NO), @[ @(targetID) ], @[])];
  FSTAssertChanged(@[ FSTTestDoc("foo/bar", 2, @{@"it" : @"changed"}, NO) ]);
  FSTAssertContains(FSTTestDoc("foo/bar", 2, @{@"it" : @"changed"}, NO));
  FSTAssertNotContains(@"bar/baz");
}

- (void)testHandlesDeletedDocumentThenSetMutationThenAck {
  if ([self isTestBaseClass]) return;

  FSTQuery *query = FSTTestQuery("foo");
  FSTTargetID targetID = [self allocateQuery:query];

  [self applyRemoteEvent:FSTTestUpdateRemoteEvent(FSTTestDeletedDoc("foo/bar", 2), @[ @(targetID) ], @[])];
  FSTAssertRemoved(@[ @"foo/bar" ]);
  FSTAssertContains(FSTTestDeletedDoc("foo/bar", 2));

  [self writeMutation:FSTTestSetMutation(@"foo/bar", @{@"foo" : @"bar"})];
  FSTAssertChanged(@[ FSTTestDoc("foo/bar", 0, @{@"foo" : @"bar"}, YES) ]);
  FSTAssertContains(FSTTestDoc("foo/bar", 0, @{@"foo" : @"bar"}, YES));
  // Can now remove the target, since we have a mutation pinning the document
  [self.localStore releaseQuery:query];
  // Verify we didn't lose anything
  FSTAssertContains(FSTTestDoc("foo/bar", 0, @{@"foo" : @"bar"}, YES));

  [self acknowledgeMutationWithVersion:3];
  FSTAssertChanged(@[ FSTTestDoc("foo/bar", 0, @{@"foo" : @"bar"}, NO) ]);
  // It has been acknowledged, and should no longer be retained as there is no target and mutation
  if ([self gcIsEager]) {
    FSTAssertNotContains(@"foo/bar");
  }
}

- (void)testHandlesSetMutationThenDeletedDocument {
  if ([self isTestBaseClass]) return;

  [self writeMutation:FSTTestSetMutation(@"foo/bar", @{@"foo" : @"bar"})];
  FSTAssertChanged(@[ FSTTestDoc("foo/bar", 0, @{@"foo" : @"bar"}, YES) ]);

  [self applyRemoteEvent:FSTTestUpdateRemoteEvent(FSTTestDeletedDoc("foo/bar", 2), @[ @1 ], @[])];
  FSTAssertChanged(@[ FSTTestDoc("foo/bar", 0, @{@"foo" : @"bar"}, YES) ]);
  FSTAssertContains(FSTTestDoc("foo/bar", 0, @{@"foo" : @"bar"}, YES));
}

- (void)testHandlesDocumentThenSetMutationThenAckThenDocument {
  if ([self isTestBaseClass]) return;

  FSTQuery *query = FSTTestQuery("foo");
  FSTTargetID targetID = [self allocateQuery:query];

  [self applyRemoteEvent:FSTTestUpdateRemoteEvent(FSTTestDoc("foo/bar", 2, @{@"it" : @"base"}, NO),
                                                  @[ @(targetID) ], @[])];
  FSTAssertChanged(@[ FSTTestDoc("foo/bar", 2, @{@"it" : @"base"}, NO) ]);
  FSTAssertContains(FSTTestDoc("foo/bar", 2, @{@"it" : @"base"}, NO));

  [self writeMutation:FSTTestSetMutation(@"foo/bar", @{@"foo" : @"bar"})];
  FSTAssertChanged(@[ FSTTestDoc("foo/bar", 2, @{@"foo" : @"bar"}, YES) ]);
  FSTAssertContains(FSTTestDoc("foo/bar", 2, @{@"foo" : @"bar"}, YES));

  [self acknowledgeMutationWithVersion:3];
  // we haven't seen the remote event yet, so the write is still held.
  FSTAssertChanged(@[]);
  FSTAssertContains(FSTTestDoc("foo/bar", 2, @{@"foo" : @"bar"}, YES));

  [self applyRemoteEvent:FSTTestUpdateRemoteEvent(
                             FSTTestDoc("foo/bar", 3, @{@"it" : @"changed"}, NO), @[ @(targetID) ], @[])];
  FSTAssertChanged(@[ FSTTestDoc("foo/bar", 3, @{@"it" : @"changed"}, NO) ]);
  FSTAssertContains(FSTTestDoc("foo/bar", 3, @{@"it" : @"changed"}, NO));
}

- (void)testHandlesPatchWithoutPriorDocument {
  if ([self isTestBaseClass]) return;

  [self writeMutation:FSTTestPatchMutation("foo/bar", @{@"foo" : @"bar"}, {})];
  FSTAssertRemoved(@[ @"foo/bar" ]);
  FSTAssertNotContains(@"foo/bar");

  [self acknowledgeMutationWithVersion:1];
  FSTAssertRemoved(@[ @"foo/bar" ]);
  FSTAssertNotContains(@"foo/bar");
}

- (void)testHandlesPatchMutationThenDocumentThenAck {
  if ([self isTestBaseClass]) return;

  [self writeMutation:FSTTestPatchMutation("foo/bar", @{@"foo" : @"bar"}, {})];
  FSTAssertRemoved(@[ @"foo/bar" ]);
  FSTAssertNotContains(@"foo/bar");

  FSTQuery *query = FSTTestQuery("foo");
  FSTTargetID targetID = [self allocateQuery:query];

  [self applyRemoteEvent:FSTTestUpdateRemoteEvent(FSTTestDoc("foo/bar", 1, @{@"it" : @"base"}, NO),
                                                  @[ @(targetID) ], @[])];
  FSTAssertChanged(@[ FSTTestDoc("foo/bar", 1, @{@"foo" : @"bar", @"it" : @"base"}, YES) ]);
  FSTAssertContains(FSTTestDoc("foo/bar", 1, @{@"foo" : @"bar", @"it" : @"base"}, YES));

  [self acknowledgeMutationWithVersion:2];
  // We still haven't seen the remote events for the patch, so the local changes remain, and there are no changes
  FSTAssertChanged(@[]);
  FSTAssertContains(FSTTestDoc("foo/bar", 1, @{@"foo" : @"bar", @"it" : @"base"}, YES));

  [self applyRemoteEvent:FSTTestUpdateRemoteEvent(FSTTestDoc("foo/bar", 2, @{@"foo": @"bar", @"it" : @"base"}, NO),
          @[], @[])];

  FSTAssertChanged(@[ FSTTestDoc("foo/bar", 1, @{@"foo" : @"bar", @"it" : @"base"}, NO) ]);
  FSTAssertContains(FSTTestDoc("foo/bar", 1, @{@"foo" : @"bar", @"it" : @"base"}, NO));
}

- (void)testHandlesPatchMutationThenAckThenDocument {
  if ([self isTestBaseClass]) return;

  [self writeMutation:FSTTestPatchMutation("foo/bar", @{@"foo" : @"bar"}, {})];
  FSTAssertRemoved(@[ @"foo/bar" ]);
  FSTAssertNotContains(@"foo/bar");

  [self acknowledgeMutationWithVersion:1];
  FSTAssertRemoved(@[ @"foo/bar" ]);
  FSTAssertNotContains(@"foo/bar");

  FSTQuery *query = FSTTestQuery("foo");
  FSTTargetID targetID = [self allocateQuery:query];

  [self applyRemoteEvent:FSTTestUpdateRemoteEvent(FSTTestDoc("foo/bar", 1, @{@"it" : @"base"}, NO),
                                                  @[ @(targetID) ], @[])];
  FSTAssertChanged(@[ FSTTestDoc("foo/bar", 1, @{@"it" : @"base"}, NO) ]);
  FSTAssertContains(FSTTestDoc("foo/bar", 1, @{@"it" : @"base"}, NO));
}

- (void)testHandlesDeleteMutationThenAck {
  if ([self isTestBaseClass]) return;

  [self writeMutation:FSTTestDeleteMutation(@"foo/bar")];
  FSTAssertRemoved(@[ @"foo/bar" ]);
  FSTAssertContains(FSTTestDeletedDoc("foo/bar", 0));

  [self acknowledgeMutationWithVersion:1];
  FSTAssertRemoved(@[ @"foo/bar" ]);
  // There's no target pinning the doc, and we've ack'd the mutation.
  if ([self gcIsEager]) {
    FSTAssertNotContains(@"foo/bar");
  }
}

- (void)testHandlesDocumentThenDeleteMutationThenAck {
  if ([self isTestBaseClass]) return;

  FSTQuery *query = FSTTestQuery("foo");
  FSTTargetID targetID = [self allocateQuery:query];

  [self applyRemoteEvent:FSTTestUpdateRemoteEvent(FSTTestDoc("foo/bar", 1, @{@"it" : @"base"}, NO),
                                                  @[ @(targetID) ], @[])];
  FSTAssertChanged(@[ FSTTestDoc("foo/bar", 1, @{@"it" : @"base"}, NO) ]);
  FSTAssertContains(FSTTestDoc("foo/bar", 1, @{@"it" : @"base"}, NO));

  [self writeMutation:FSTTestDeleteMutation(@"foo/bar")];
  FSTAssertRemoved(@[ @"foo/bar" ]);
  FSTAssertContains(FSTTestDeletedDoc("foo/bar", 0));

  // Remove the target so only the mutation is pinning the document
  [self.localStore releaseQuery:query];
  [self acknowledgeMutationWithVersion:2];
  FSTAssertRemoved(@[ @"foo/bar" ]);
  if ([self gcIsEager]) {
    // Neither the target nor the mutation pin the document, it should be gone.
    FSTAssertNotContains(@"foo/bar");
  }
}

- (void)testHandlesDeleteMutationThenDocumentThenAck {
  if ([self isTestBaseClass]) return;

  FSTQuery *query = FSTTestQuery("foo");
  FSTTargetID targetID = [self allocateQuery:query];

  [self writeMutation:FSTTestDeleteMutation(@"foo/bar")];
  FSTAssertRemoved(@[ @"foo/bar" ]);
  FSTAssertContains(FSTTestDeletedDoc("foo/bar", 0));

  // Add the document to a target so it will remain in persistence even when ack'd
  [self applyRemoteEvent:FSTTestUpdateRemoteEvent(FSTTestDoc("foo/bar", 1, @{@"it" : @"base"}, NO),
                                                  @[ @(targetID) ], @[])];
  FSTAssertRemoved(@[ @"foo/bar" ]);
  FSTAssertContains(FSTTestDeletedDoc("foo/bar", 0));

  // Don't need to keep it pinned anymore
  [self.localStore releaseQuery:query];

  [self acknowledgeMutationWithVersion:2];
  FSTAssertRemoved(@[ @"foo/bar" ]);
  if ([self gcIsEager]) {
    // The doc is not pinned in a target and we've acknowledged the mutation. It shouldn't exist anymore.
    FSTAssertNotContains(@"foo/bar");
  }
}

- (void)testHandlesDocumentThenDeletedDocumentThenDocument {
  if ([self isTestBaseClass]) return;

  FSTQuery *query = FSTTestQuery("foo");
  FSTTargetID targetID = [self allocateQuery:query];

  [self applyRemoteEvent:FSTTestUpdateRemoteEvent(FSTTestDoc("foo/bar", 1, @{@"it" : @"base"}, NO),
                                                  @[ @(targetID) ], @[])];
  FSTAssertChanged(@[ FSTTestDoc("foo/bar", 1, @{@"it" : @"base"}, NO) ]);
  FSTAssertContains(FSTTestDoc("foo/bar", 1, @{@"it" : @"base"}, NO));

  [self applyRemoteEvent:FSTTestUpdateRemoteEvent(FSTTestDeletedDoc("foo/bar", 2), @[ @(targetID) ], @[])];
  FSTAssertRemoved(@[ @"foo/bar" ]);
  FSTAssertContains(FSTTestDeletedDoc("foo/bar", 2));

  [self applyRemoteEvent:FSTTestUpdateRemoteEvent(
                             FSTTestDoc("foo/bar", 3, @{@"it" : @"changed"}, NO), @[ @(targetID) ], @[])];
  FSTAssertChanged(@[ FSTTestDoc("foo/bar", 3, @{@"it" : @"changed"}, NO) ]);
  FSTAssertContains(FSTTestDoc("foo/bar", 3, @{@"it" : @"changed"}, NO));
}

- (void)testHandlesSetMutationThenPatchMutationThenDocumentThenAckThenAck {
  if ([self isTestBaseClass]) return;

  [self writeMutation:FSTTestSetMutation(@"foo/bar", @{@"foo" : @"old"})];
  FSTAssertChanged(@[ FSTTestDoc("foo/bar", 0, @{@"foo" : @"old"}, YES) ]);
  FSTAssertContains(FSTTestDoc("foo/bar", 0, @{@"foo" : @"old"}, YES));

  [self writeMutation:FSTTestPatchMutation("foo/bar", @{@"foo" : @"bar"}, {})];
  FSTAssertChanged(@[ FSTTestDoc("foo/bar", 0, @{@"foo" : @"bar"}, YES) ]);
  FSTAssertContains(FSTTestDoc("foo/bar", 0, @{@"foo" : @"bar"}, YES));

  [self applyRemoteEvent:FSTTestUpdateRemoteEvent(FSTTestDoc("foo/bar", 1, @{@"it" : @"base"}, NO),
                                                  @[ @1 ], @[])];
  FSTAssertChanged(@[ FSTTestDoc("foo/bar", 1, @{@"foo" : @"bar"}, YES) ]);
  FSTAssertContains(FSTTestDoc("foo/bar", 1, @{@"foo" : @"bar"}, YES));

  [self acknowledgeMutationWithVersion:2];  // delete mutation
  FSTAssertChanged(@[ FSTTestDoc("foo/bar", 1, @{@"foo" : @"bar"}, YES) ]);
  FSTAssertContains(FSTTestDoc("foo/bar", 1, @{@"foo" : @"bar"}, YES));

  [self acknowledgeMutationWithVersion:3];  // patch mutation
  FSTAssertChanged(@[ FSTTestDoc("foo/bar", 1, @{@"foo" : @"bar"}, NO) ]);
  if ([self gcIsEager]) {
    // we've ack'd all of the mutations, nothing is keeping this pinned anymore
    FSTAssertNotContains(@"foo/bar");
  }
}

- (void)testHandlesSetMutationAndPatchMutationTogether {
  if ([self isTestBaseClass]) return;

  [self writeMutations:@[
    FSTTestSetMutation(@"foo/bar", @{@"foo" : @"old"}),
    FSTTestPatchMutation("foo/bar", @{@"foo" : @"bar"}, {})
  ]];

  FSTAssertChanged(@[ FSTTestDoc("foo/bar", 0, @{@"foo" : @"bar"}, YES) ]);
  FSTAssertContains(FSTTestDoc("foo/bar", 0, @{@"foo" : @"bar"}, YES));
}

- (void)testHandlesSetMutationThenPatchMutationThenReject {
  if ([self isTestBaseClass]) return;
  if (![self gcIsEager]) return;

  [self writeMutation:FSTTestSetMutation(@"foo/bar", @{@"foo" : @"old"})];
  FSTAssertContains(FSTTestDoc("foo/bar", 0, @{@"foo" : @"old"}, YES));
  [self acknowledgeMutationWithVersion:1];
  FSTAssertNotContains(@"foo/bar");

  [self writeMutation:FSTTestPatchMutation("foo/bar", @{@"foo" : @"bar"}, {})];
  // A blind patch is not visible in the cache
  FSTAssertNotContains(@"foo/bar");
  //FSTAssertContains(FSTTestDoc("foo/bar", 0, @{@"foo" : @"bar"}, YES));

  [self rejectMutation];
  FSTAssertNotContains(@"foo/bar");
  //FSTAssertChanged(@[ FSTTestDoc("foo/bar", 0, @{@"foo" : @"old"}, NO) ]);
  //FSTAssertContains(FSTTestDoc("foo/bar", 0, @{@"foo" : @"old"}, NO));
}

- (void)testHandlesSetMutationsAndPatchMutationOfJustOneTogether {
  if ([self isTestBaseClass]) return;

  [self writeMutations:@[
    FSTTestSetMutation(@"foo/bar", @{@"foo" : @"old"}),
    FSTTestSetMutation(@"bar/baz", @{@"bar" : @"baz"}),
    FSTTestPatchMutation("foo/bar", @{@"foo" : @"bar"}, {})
  ]];

  FSTAssertChanged((@[
    FSTTestDoc("bar/baz", 0, @{@"bar" : @"baz"}, YES),
    FSTTestDoc("foo/bar", 0, @{@"foo" : @"bar"}, YES)
  ]));
  FSTAssertContains(FSTTestDoc("foo/bar", 0, @{@"foo" : @"bar"}, YES));
  FSTAssertContains(FSTTestDoc("bar/baz", 0, @{@"bar" : @"baz"}, YES));
}

- (void)testHandlesDeleteMutationThenPatchMutationThenAckThenAck {
  if ([self isTestBaseClass]) return;

  [self writeMutation:FSTTestDeleteMutation(@"foo/bar")];
  FSTAssertRemoved(@[ @"foo/bar" ]);
  FSTAssertContains(FSTTestDeletedDoc("foo/bar", 0));

  [self writeMutation:FSTTestPatchMutation("foo/bar", @{@"foo" : @"bar"}, {})];
  FSTAssertRemoved(@[ @"foo/bar" ]);
  FSTAssertContains(FSTTestDeletedDoc("foo/bar", 0));

  [self acknowledgeMutationWithVersion:2];  // delete mutation
  FSTAssertRemoved(@[ @"foo/bar" ]);
  FSTAssertContains(FSTTestDeletedDoc("foo/bar", 0));

  [self acknowledgeMutationWithVersion:3];  // patch mutation
  FSTAssertRemoved(@[ @"foo/bar" ]);
  if ([self gcIsEager]) {
    // There are no more pending mutations, the doc has been dropped
    FSTAssertNotContains(@"foo/bar");
  }
}

- (void)testCollectsGarbageAfterChangeBatchWithNoTargetIDs {
  if ([self isTestBaseClass]) return;
  if (![self gcIsEager]) return;

  [self applyRemoteEvent:FSTTestUpdateRemoteEvent(FSTTestDeletedDoc("foo/bar", 2), @[ @1 ], @[])];
  FSTAssertRemoved(@[ @"foo/bar" ]);

  [self collectGarbage];
  FSTAssertNotContains(@"foo/bar");

  [self applyRemoteEvent:FSTTestUpdateRemoteEvent(FSTTestDoc("foo/bar", 2, @{@"foo" : @"bar"}, NO),
                                                  @[ @1 ], @[])];
  [self collectGarbage];
  FSTAssertNotContains(@"foo/bar");
}

- (void)testCollectsGarbageAfterChangeBatch {
  if ([self isTestBaseClass]) return;
  if (![self gcIsEager]) return;

  FSTQuery *query = FSTTestQuery("foo");
  [self allocateQuery:query];
  FSTAssertTargetID(2);

  [self applyRemoteEvent:FSTTestUpdateRemoteEvent(FSTTestDoc("foo/bar", 2, @{@"foo" : @"bar"}, NO),
                                                  @[ @2 ], @[])];
  [self collectGarbage];
  FSTAssertContains(FSTTestDoc("foo/bar", 2, @{@"foo" : @"bar"}, NO));

  [self applyRemoteEvent:FSTTestUpdateRemoteEvent(FSTTestDoc("foo/bar", 2, @{@"foo" : @"baz"}, NO),
                                                  @[], @[ @2 ])];
  [self collectGarbage];

  FSTAssertNotContains(@"foo/bar");
}

- (void)testCollectsGarbageAfterAcknowledgedMutation {
  if ([self isTestBaseClass]) return;
  if (![self gcIsEager]) return;

  FSTQuery *query = FSTTestQuery("foo");
  [self allocateQuery:query];
  FSTAssertTargetID(2);

  // Cache something for foo/bar, since we need it in order to patch.
  [self applyRemoteEvent:FSTTestUpdateRemoteEvent(FSTTestDoc("foo/bar", 0, @{@"foo" : @"old"}, NO),
                                                  @[ @2 ], @[])];
  // Apply patch, pins the document in the mutation queue
  [self writeMutation:FSTTestPatchMutation("foo/bar", @{@"foo" : @"bar"}, {})];
  // Release the query so that our target count goes back to 0 and we are considered up-to-date.
  [self.localStore releaseQuery:query];

  [self writeMutation:FSTTestSetMutation(@"foo/bah", @{@"foo" : @"bah"})];
  [self writeMutation:FSTTestDeleteMutation(@"foo/baz")];
  [self collectGarbage];
  FSTAssertContains(FSTTestDoc("foo/bar", 0, @{@"foo" : @"bar"}, YES));
  FSTAssertContains(FSTTestDoc("foo/bah", 0, @{@"foo" : @"bah"}, YES));
  FSTAssertContains(FSTTestDeletedDoc("foo/baz", 0));

  [self acknowledgeMutationWithVersion:3];
  [self collectGarbage];
  FSTAssertNotContains(@"foo/bar");
  FSTAssertContains(FSTTestDoc("foo/bah", 0, @{@"foo" : @"bah"}, YES));
  FSTAssertContains(FSTTestDeletedDoc("foo/baz", 0));

  [self acknowledgeMutationWithVersion:4];
  [self collectGarbage];
  FSTAssertNotContains(@"foo/bar");
  FSTAssertNotContains(@"foo/bah");
  FSTAssertContains(FSTTestDeletedDoc("foo/baz", 0));

  [self acknowledgeMutationWithVersion:5];
  [self collectGarbage];
  FSTAssertNotContains(@"foo/bar");
  FSTAssertNotContains(@"foo/bah");
  FSTAssertNotContains(@"foo/baz");
}

- (void)testCollectsGarbageAfterRejectedMutation {
  if ([self isTestBaseClass]) return;
  if (![self gcIsEager]) return;

  FSTQuery *query = FSTTestQuery("foo");
  [self allocateQuery:query];
  FSTAssertTargetID(2);

  // Cache something for foo/bar, since we need it in order to patch.
  [self applyRemoteEvent:FSTTestUpdateRemoteEvent(FSTTestDoc("foo/bar", 0, @{@"foo" : @"old"}, NO),
          @[ @2 ], @[])];
  [self writeMutation:FSTTestPatchMutation("foo/bar", @{@"foo" : @"bar"}, {})];
  // Release the query so that our target count goes back to 0 and we are considered up-to-date.
  [self.localStore releaseQuery:query];

  [self writeMutation:FSTTestSetMutation(@"foo/bah", @{@"foo" : @"bah"})];
  [self writeMutation:FSTTestDeleteMutation(@"foo/baz")];
  [self collectGarbage];
  FSTAssertContains(FSTTestDoc("foo/bar", 0, @{@"foo" : @"bar"}, YES));
  FSTAssertContains(FSTTestDoc("foo/bah", 0, @{@"foo" : @"bah"}, YES));
  FSTAssertContains(FSTTestDeletedDoc("foo/baz", 0));

  [self rejectMutation];  // patch mutation
  [self collectGarbage];
  FSTAssertNotContains(@"foo/bar");
  FSTAssertContains(FSTTestDoc("foo/bah", 0, @{@"foo" : @"bah"}, YES));
  FSTAssertContains(FSTTestDeletedDoc("foo/baz", 0));

  [self rejectMutation];  // set mutation
  [self collectGarbage];
  FSTAssertNotContains(@"foo/bar");
  FSTAssertNotContains(@"foo/bah");
  FSTAssertContains(FSTTestDeletedDoc("foo/baz", 0));

  [self rejectMutation];  // delete mutation
  [self collectGarbage];
  FSTAssertNotContains(@"foo/bar");
  FSTAssertNotContains(@"foo/bah");
  FSTAssertNotContains(@"foo/baz");
}

- (void)testPinsDocumentsInTheLocalView {
  if ([self isTestBaseClass]) return;
  if (![self gcIsEager]) return;

  FSTQuery *query = FSTTestQuery("foo");
  [self allocateQuery:query];
  FSTAssertTargetID(2);

  [self applyRemoteEvent:FSTTestUpdateRemoteEvent(FSTTestDoc("foo/bar", 1, @{@"foo" : @"bar"}, NO),
                                                  @[ @2 ], @[])];
  [self writeMutation:FSTTestSetMutation(@"foo/baz", @{@"foo" : @"baz"})];
  [self collectGarbage];
  FSTAssertContains(FSTTestDoc("foo/bar", 1, @{@"foo" : @"bar"}, NO));
  FSTAssertContains(FSTTestDoc("foo/baz", 0, @{@"foo" : @"baz"}, YES));

  [self notifyLocalViewChanges:FSTTestViewChanges(query, @[ @"foo/bar", @"foo/baz" ], @[])];
  FSTAssertContains(FSTTestDoc("foo/bar", 1, @{@"foo" : @"bar"}, NO));
  [self applyRemoteEvent:FSTTestUpdateRemoteEvent(FSTTestDoc("foo/bar", 1, @{@"foo" : @"bar"}, NO),
                                                  @[], @[ @2 ])];
  // Note: non-existent target. Kept as referenced by local view.
  [self applyRemoteEvent:FSTTestUpdateRemoteEvent(FSTTestDoc("foo/baz", 2, @{@"foo" : @"baz"}, NO),
                                                  @[ @1 ], @[])];
  FSTAssertContains(FSTTestDoc("foo/baz", 2, @{@"foo" : @"baz"}, YES));
  [self acknowledgeMutationWithVersion:2];
  FSTAssertContains(FSTTestDoc("foo/baz", 2, @{@"foo" : @"baz"}, NO));
  [self collectGarbage];
  FSTAssertContains(FSTTestDoc("foo/bar", 1, @{@"foo" : @"bar"}, NO));
  FSTAssertContains(FSTTestDoc("foo/baz", 2, @{@"foo" : @"baz"}, NO));

  [self notifyLocalViewChanges:FSTTestViewChanges(query, @[], @[ @"foo/bar", @"foo/baz" ])];
  [self collectGarbage];

  FSTAssertNotContains(@"foo/bar");
  FSTAssertNotContains(@"foo/baz");
}

- (id<FSTQueryCache>)queryCache {
  id result = [self.localStore performSelector:@selector(queryCache)];
  return (id<FSTQueryCache>)result;
}

- (void)testThrowsAwayDocumentsWithUnknownTargetIDsImmediately {
  if ([self isTestBaseClass]) return;
  // TODO(gsoltis): suspect that this needs to be handled by LRU
  //if (![self gcIsEager]) return;

  FSTTargetID targetID = 321;
  [self applyRemoteEvent:FSTTestUpdateRemoteEvent(FSTTestDoc("foo/bar", 1, @{}, NO),
                                                  @[ @(targetID) ], @[])];
  //FSTAssertContains(FSTTestDoc("foo/bar", 1, @{}, NO));

  //[self collectGarbage];
  FSTAssertNotContains(@"foo/bar");
}

- (void)testCanExecuteDocumentQueries {
  if ([self isTestBaseClass]) return;

  [self.localStore locallyWriteMutations:@[
    FSTTestSetMutation(@"foo/bar", @{@"foo" : @"bar"}),
    FSTTestSetMutation(@"foo/baz", @{@"foo" : @"baz"}),
    FSTTestSetMutation(@"foo/bar/Foo/Bar", @{@"Foo" : @"Bar"})
  ]];
  FSTQuery *query = FSTTestQuery("foo/bar");
  FSTDocumentDictionary *docs = [self.localStore executeQuery:query];
  XCTAssertEqualObjects([docs values], @[ FSTTestDoc("foo/bar", 0, @{@"foo" : @"bar"}, YES) ]);
}

- (void)testCanExecuteCollectionQueries {
  if ([self isTestBaseClass]) return;

  [self.localStore locallyWriteMutations:@[
    FSTTestSetMutation(@"fo/bar", @{@"fo" : @"bar"}),
    FSTTestSetMutation(@"foo/bar", @{@"foo" : @"bar"}),
    FSTTestSetMutation(@"foo/baz", @{@"foo" : @"baz"}),
    FSTTestSetMutation(@"foo/bar/Foo/Bar", @{@"Foo" : @"Bar"}),
    FSTTestSetMutation(@"fooo/blah", @{@"fooo" : @"blah"})
  ]];
  FSTQuery *query = FSTTestQuery("foo");
  FSTDocumentDictionary *docs = [self.localStore executeQuery:query];
  XCTAssertEqualObjects([docs values], (@[
                          FSTTestDoc("foo/bar", 0, @{@"foo" : @"bar"}, YES),
                          FSTTestDoc("foo/baz", 0, @{@"foo" : @"baz"}, YES)
                        ]));
}

- (void)testCanExecuteMixedCollectionQueries {
  if ([self isTestBaseClass]) return;

  FSTQuery *query = FSTTestQuery("foo");
  [self allocateQuery:query];
  FSTAssertTargetID(2);

  [self applyRemoteEvent:FSTTestUpdateRemoteEvent(FSTTestDoc("foo/baz", 10, @{@"a" : @"b"}, NO),
                                                  @[ @2 ], @[])];
  [self applyRemoteEvent:FSTTestUpdateRemoteEvent(FSTTestDoc("foo/bar", 20, @{@"a" : @"b"}, NO),
                                                  @[ @2 ], @[])];

  [self.localStore locallyWriteMutations:@[ FSTTestSetMutation(@"foo/bonk", @{@"a" : @"b"}) ]];

  FSTDocumentDictionary *docs = [self.localStore executeQuery:query];
  XCTAssertEqualObjects([docs values], (@[
                          FSTTestDoc("foo/bar", 20, @{@"a" : @"b"}, NO),
                          FSTTestDoc("foo/baz", 10, @{@"a" : @"b"}, NO),
                          FSTTestDoc("foo/bonk", 0, @{@"a" : @"b"}, YES)
                        ]));
}

- (void)testPersistsResumeTokens {
  if ([self isTestBaseClass]) return;
  // This test only works in the absence of the FSTEagerGarbageCollector.
  if ([self gcIsEager]) return;

  FSTQuery *query = FSTTestQuery("foo/bar");
  FSTQueryData *queryData = [self.localStore allocateQuery:query];
  FSTBoxedTargetID *targetID = @(queryData.targetID);
  NSData *resumeToken = FSTTestResumeTokenFromSnapshotVersion(1000);

  FSTWatchChange *watchChange =
      [FSTWatchTargetChange changeWithState:FSTWatchTargetChangeStateCurrent
                                  targetIDs:@[ targetID ]
                                resumeToken:resumeToken];
  NSMutableDictionary<FSTBoxedTargetID *, FSTQueryData *> *listens =
      [NSMutableDictionary dictionary];
  listens[targetID] = queryData;
  NSMutableDictionary<FSTBoxedTargetID *, NSNumber *> *pendingResponses =
      [NSMutableDictionary dictionary];
  FSTWatchChangeAggregator *aggregator =
      [[FSTWatchChangeAggregator alloc] initWithSnapshotVersion:FSTTestVersion(1000)
                                                  listenTargets:listens
                                         pendingTargetResponses:pendingResponses];
  [aggregator addWatchChanges:@[ watchChange ]];
  FSTRemoteEvent *remoteEvent = [aggregator remoteEvent];
  [self applyRemoteEvent:remoteEvent];

  // Stop listening so that the query should become inactive (but persistent)
  [self.localStore releaseQuery:query];

  // Should come back with the same resume token
  FSTQueryData *queryData2 = [self.localStore allocateQuery:query];
  XCTAssertEqualObjects(queryData2.resumeToken, resumeToken);
}

- (void)testRemoteDocumentKeysForTarget {
  if ([self isTestBaseClass]) return;

  FSTQuery *query = FSTTestQuery("foo");
  [self allocateQuery:query];
  FSTAssertTargetID(2);

  [self applyRemoteEvent:FSTTestUpdateRemoteEvent(FSTTestDoc("foo/baz", 10, @{@"a" : @"b"}, NO),
                                                  @[ @2 ], @[])];
  [self applyRemoteEvent:FSTTestUpdateRemoteEvent(FSTTestDoc("foo/bar", 20, @{@"a" : @"b"}, NO),
                                                  @[ @2 ], @[])];

  [self.localStore locallyWriteMutations:@[ FSTTestSetMutation(@"foo/bonk", @{@"a" : @"b"}) ]];

  FSTDocumentKeySet *keys = [self.localStore remoteDocumentKeysForTarget:2];
  FSTAssertEqualSets(keys, (@[ FSTTestDocKey(@"foo/bar"), FSTTestDocKey(@"foo/baz") ]));

  keys = [self.localStore remoteDocumentKeysForTarget:2];
  FSTAssertEqualSets(keys, (@[ FSTTestDocKey(@"foo/bar"), FSTTestDocKey(@"foo/baz") ]));
}

@end

NS_ASSUME_NONNULL_END
