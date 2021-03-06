/**
 * Copyright (c) 2013, Andrew Fawcett
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, 
 *   are permitted provided that the following conditions are met:
 *
 * - Redistributions of source code must retain the above copyright notice, 
 *      this list of conditions and the following disclaimer.
 * - Redistributions in binary form must reproduce the above copyright notice, 
 *      this list of conditions and the following disclaimer in the documentation 
 *      and/or other materials provided with the distribution.
 * - Neither the name of the Andrew Fawcett, nor the names of its contributors 
 *      may be used to endorse or promote products derived from this software without 
 *      specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND 
 *  ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES 
 *  OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL 
 *  THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, 
 *  EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 *  OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 *  OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 *  ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
**/

/**
 * Tests the RollupService methods, note the LREngine is test independently via TestLREngine
 **/
@IsTest
private with sharing class RollupServiceTest3 
{		
	static Schema.SObjectField ACCOUNT_SLA_EXPIRATION_DATE;
	static Schema.SObjectField ACCOUNT_NUMBER_OF_LOCATIONS;		
	static
	{
		// Dynamically resolve these fields, if they are not present when the test runs, the test will return as passed to avoid failures in subscriber org when packaged
		Map<String, Schema.SObjectField> accountFields = Schema.SObjectType.Account.fields.getMap();
		ACCOUNT_SLA_EXPIRATION_DATE = accountFields.get('SLAExpirationDate__c');
		ACCOUNT_NUMBER_OF_LOCATIONS = accountFields.get('NumberOfLocations__c');
	}
	
	private testmethod static void testCalculateJob()
	{		
		// Test supported?
		if(!TestContext.isSupported())
			return;

		Schema.SObjectType parentType = LookupParent__c.sObjectType;
		Schema.SObjectType childType = LookupChild__c.sObjectType;
		String parentObjectName = parentType.getDescribe().getName();
		String childObjectName = childType.getDescribe().getName();
		String relationshipField = LookupChild__c.LookupParent__c.getDescribe().getName();
		String aggregateField = LookupChild__c.Amount__c.getDescribe().getName();
		String aggregateResultField = LookupParent__c.Total__c.getDescribe().getName();

		// Insert parents
		SObject parentA = parentType.newSObject();
		parentA.put('Name', 'ParentA');
		SObject parentB = parentType.newSObject();
		parentB.put('Name', 'ParentB');
		SObject parentC = parentType.newSObject();
		parentC.put('Name', 'ParentC');
		List<SObject> parents = new List<SObject> { parentA, parentB, parentC };
		insert parents;

		// Insert children
		List<SObject> children = new List<SObject>();
		for(SObject parent : parents)
		{
			String name = (String) parent.get('Name');
			SObject child1 = childType.newSObject();
			child1.put(relationshipField, parent.Id);
			child1.put(aggregateField, 20);
			children.add(child1);
			SObject child2 = childType.newSObject();
			child2.put(relationshipField, parent.Id);
			child2.put(aggregateField, 20);
			children.add(child2);
			if(name.equals('ParentA') || name.equals('ParentB'))
			{
				SObject child3 = childType.newSObject();
				child3.put(relationshipField, parent.Id);
				child3.put(aggregateField, 2);
				children.add(child3);
			}
		}
		insert children;

		// Create rollup AFTER the data exists
		LookupRollupSummary__c rollupSummary = new LookupRollupSummary__c();
		rollupSummary.Name = 'Test Rollup';
		rollupSummary.ParentObject__c = parentObjectName;
		rollupSummary.ChildObject__c = childObjectName;
		rollupSummary.RelationShipField__c = relationshipField;
		rollupSummary.FieldToAggregate__c = aggregateField;
		rollupSummary.AggregateOperation__c = RollupSummaries.AggregateOperation.Sum.name();
		rollupSummary.AggregateResultField__c = aggregateResultField;
		rollupSummary.Active__c = true;
		rollupSummary.CalculationMode__c = 'Scheduled';
		insert rollupSummary;

		// Run rollup calculate job
		Test.startTest();
		Id jobId = RollupService.runJobToCalculate(rollupSummary.Id);
		rollupSummary = [select Id, CalculateJobId__c from LookupRollupSummary__c where Id  = :rollupSummary.Id];
		System.assertEquals(jobId, rollupSummary.CalculateJobId__c); // Assert job id captured
		try {
			// Assert not possible to start another
			RollupService.runJobToCalculate(rollupSummary.Id);
			System.assert(false, 'Expected an exception');
		} catch (Exception e) {
			System.assert(e.getMessage().equals('A calculate job for rollup \'Test Rollup\' is already executing. If you suspect it is not aleady running try clearing the Calculate Job Id field and try again.'));
		}
		Test.stopTest();
		// Assert job id cleared
		rollupSummary = [select Id, CalculateJobId__c from LookupRollupSummary__c where Id  = :rollupSummary.Id];
		System.assertEquals(null, rollupSummary.CalculateJobId__c); 

		// This should not generate any schedule items
		System.assertEquals(0, [select id from LookupRollupSummaryScheduleItems__c].size());

		// Assert rollups
		Map<Id, SObject> assertParents = new Map<Id, SObject>(Database.query(String.format('select id, {0} from {1}', new List<String>{ aggregateResultField, parentObjectName })));
		System.assertEquals(42, (Decimal) assertParents.get(parentA.id).get(aggregateResultField));
		System.assertEquals(42, (Decimal) assertParents.get(parentB.id).get(aggregateResultField));
		System.assertEquals(null, (Decimal) assertParents.get(parentC.id).get(aggregateResultField));

		// Assert scheduled items and log records
		List<LookupRollupSummaryLog__c> logs = [select id, ParentId__c, ParentObject__c, ErrorMessage__c from LookupRollupSummaryLog__c];
		System.assertEquals(parentC.Id, logs[0].ParentId__c);
		System.assertEquals(parentObjectName, logs[0].ParentObject__c);
		System.assertEquals(1, logs.size());
		System.assertEquals('The answer is not 42! : FIELD_CUSTOM_VALIDATION_EXCEPTION (' + aggregateResultField + ')', logs[0].ErrorMessage__c);
	}

	private testmethod static void testFilteredCalculateJob()
	{
		// Test supported?
		if(!TestContext.isSupported())
			return;

		Schema.SObjectType parentType = LookupParent__c.sObjectType;
		Schema.SObjectType childType = LookupChild__c.sObjectType;
		String parentObjectName = parentType.getDescribe().getName();
		String childObjectName = childType.getDescribe().getName();
		String relationshipField = LookupChild__c.LookupParent__c.getDescribe().getName();
		String aggregateField = LookupChild__c.Amount__c.getDescribe().getName();
		String aggregateResultField = LookupParent__c.Total__c.getDescribe().getName();

		// Insert parents
		SObject parentA = parentType.newSObject();
		parentA.put('Name', 'ParentA');
		SObject parentB = parentType.newSObject();
		parentB.put('Name', 'ParentB');
		SObject parentC = parentType.newSObject();
		parentC.put('Name', 'ParentC');
		List<SObject> parents = new List<SObject> { parentA, parentB, parentC };
		insert parents;

		// Insert children
		List<SObject> children = new List<SObject>();
		for(SObject parent : parents)
		{
			String name = (String) parent.get('Name');
			SObject child1 = childType.newSObject();
			child1.put(relationshipField, parent.Id);
			child1.put(aggregateField, 20);
			children.add(child1);
			SObject child2 = childType.newSObject();
			child2.put(relationshipField, parent.Id);
			child2.put(aggregateField, 20);
			children.add(child2);
			if(name.equals('ParentA') || name.equals('ParentB'))
			{
				SObject child3 = childType.newSObject();
				child3.put(relationshipField, parent.Id);
				child3.put(aggregateField, 2);
				children.add(child3);
			}
		}
		insert children;

		// Create rollup AFTER the data exists
		LookupRollupSummary__c rollupSummary = new LookupRollupSummary__c();
		rollupSummary.Name = 'Test Rollup';
		rollupSummary.ParentObject__c = parentObjectName;
		rollupSummary.ChildObject__c = childObjectName;
		rollupSummary.RelationShipField__c = relationshipField;
		rollupSummary.FieldToAggregate__c = aggregateField;
		rollupSummary.AggregateOperation__c = RollupSummaries.AggregateOperation.Sum.name();
		rollupSummary.AggregateResultField__c = aggregateResultField;
		rollupSummary.Active__c = true;
		rollupSummary.CalculationMode__c = 'Scheduled';
		insert rollupSummary;

		// Run rollup calculate job with WHERE clause
		Test.startTest();
		Id jobId = RollupService.runJobToCalculate(rollupSummary.Id, 'Name = \'ParentB\'');
		Test.stopTest();

		// This should not generate any schedule items
		System.assertEquals(0, [select id from LookupRollupSummaryScheduleItems__c].size());

		// Assert rollups
		Map<Id, SObject> assertParents = new Map<Id, SObject>(Database.query(String.format('select id, {0} from {1}', new List<String>{ aggregateResultField, parentObjectName })));
		System.assertEquals(null, (Decimal) assertParents.get(parentA.id).get(aggregateResultField));
		System.assertEquals(42, (Decimal) assertParents.get(parentB.id).get(aggregateResultField));
		System.assertEquals(null, (Decimal) assertParents.get(parentC.id).get(aggregateResultField));

		// Assert scheduled items and log records
		List<LookupRollupSummaryLog__c> logs = [select id, ParentId__c, ParentObject__c, ErrorMessage__c from LookupRollupSummaryLog__c];
		System.assertEquals(0, logs.size());
	}

	private testmethod static void testCalculateJobNotActive()
	{
		// Test supported?
		if(!TestContext.isSupported())
			return;

		Schema.SObjectType parentType = LookupParent__c.sObjectType;
		Schema.SObjectType childType = LookupChild__c.sObjectType;
		String parentObjectName = parentType.getDescribe().getName();
		String childObjectName = childType.getDescribe().getName();
		String relationshipField = LookupChild__c.LookupParent__c.getDescribe().getName();
		String aggregateField = LookupChild__c.Amount__c.getDescribe().getName();
		String aggregateResultField = LookupParent__c.Total__c.getDescribe().getName();

		// Insert parents
		SObject parentA = parentType.newSObject();
		parentA.put('Name', 'ParentA');
		SObject parentB = parentType.newSObject();
		parentB.put('Name', 'ParentB');
		SObject parentC = parentType.newSObject();
		parentC.put('Name', 'ParentC');
		List<SObject> parents = new List<SObject> { parentA, parentB, parentC };
		insert parents;

		// Insert children
		List<SObject> children = new List<SObject>();
		for(SObject parent : parents)
		{
			String name = (String) parent.get('Name');
			SObject child1 = childType.newSObject();
			child1.put(relationshipField, parent.Id);
			child1.put(aggregateField, 20);
			children.add(child1);
			SObject child2 = childType.newSObject();
			child2.put(relationshipField, parent.Id);
			child2.put(aggregateField, 20);
			children.add(child2);
			if(name.equals('ParentA') || name.equals('ParentB'))
			{
				SObject child3 = childType.newSObject();
				child3.put(relationshipField, parent.Id);
				child3.put(aggregateField, 2);
				children.add(child3);
			}
		}
		insert children;

		// Create rollup AFTER the data exists
		LookupRollupSummary__c rollupSummary = new LookupRollupSummary__c();
		rollupSummary.Name = 'Test Rollup';
		rollupSummary.ParentObject__c = parentObjectName;
		rollupSummary.ChildObject__c = childObjectName;
		rollupSummary.RelationShipField__c = relationshipField;
		rollupSummary.FieldToAggregate__c = aggregateField;
		rollupSummary.AggregateOperation__c = RollupSummaries.AggregateOperation.Sum.name();
		rollupSummary.AggregateResultField__c = aggregateResultField;
		rollupSummary.Active__c = false;
		rollupSummary.CalculationMode__c = 'Scheduled';
		insert rollupSummary;

		// Run rollup calculate job
		Test.startTest();
		try {
			// Assert not possible to start another
			RollupService.runJobToCalculate(rollupSummary.Id);
			System.assert(false, 'Expected an exception');
		} catch (Exception e) {
			System.assert(e.getMessage().equals('The rollup must be Active before you can run a Calculate job.'));
		}
		Test.stopTest();
	}

	private testmethod static void testDeveloperAPI()
	{
		// Test supported?
		if(!TestContext.isSupported())
			return;

		Schema.SObjectType parentType = LookupParent__c.sObjectType;
		Schema.SObjectType childType = LookupChild__c.sObjectType;
		String parentObjectName = parentType.getDescribe().getName();
		String childObjectName = childType.getDescribe().getName();
		String relationshipField = LookupChild__c.LookupParent__c.getDescribe().getName();
		String aggregateField = LookupChild__c.Amount__c.getDescribe().getName();
		String aggregateResultField = LookupParent__c.Total__c.getDescribe().getName();

		// Create rollup
		LookupRollupSummary__c rollupSummary = new LookupRollupSummary__c();
		rollupSummary.Name = 'Test Rollup';
		rollupSummary.ParentObject__c = parentObjectName;
		rollupSummary.ChildObject__c = childObjectName;
		rollupSummary.RelationShipField__c = relationshipField;
		rollupSummary.FieldToAggregate__c = aggregateField;
		rollupSummary.AggregateOperation__c = RollupSummaries.AggregateOperation.Sum.name();
		rollupSummary.AggregateResultField__c = aggregateResultField;
		rollupSummary.Active__c = true;
		rollupSummary.CalculationMode__c = RollupSummaries.CalculationMode.Developer.name();
		insert rollupSummary;

		// Insert parents
		SObject parentA = parentType.newSObject();
		parentA.put('Name', 'ParentA');
		SObject parentB = parentType.newSObject();
		parentB.put('Name', 'ParentB');
		SObject parentC = parentType.newSObject();
		parentC.put('Name', 'ParentC');
		List<SObject> parents = new List<SObject> { parentA, parentB, parentC };
		insert parents;

		// Insert children
		List<SObject> children = new List<SObject>();
		for(SObject parent : parents)
		{
			String name = (String) parent.get('Name');
			SObject child1 = childType.newSObject();
			child1.put(relationshipField, parent.Id);
			child1.put(aggregateField, 20);
			children.add(child1);
			SObject child2 = childType.newSObject();
			child2.put(relationshipField, parent.Id);
			child2.put(aggregateField, 20);
			children.add(child2);
			if(name.equals('ParentA') || name.equals('ParentB'))
			{
				SObject child3 = childType.newSObject();
				child3.put(relationshipField, parent.Id);
				child3.put(aggregateField, 2);
				children.add(child3);
			}
		}
		insert children;

		// Assert nothing has changed on db
		Map<Id, SObject> assertParents = new Map<Id, SObject>(Database.query(String.format('select id, {0} from {1}', new List<String>{ aggregateResultField, parentObjectName })));
		System.assertEquals(null, (Decimal) assertParents.get(parentA.id).get(aggregateResultField));
		System.assertEquals(null, (Decimal) assertParents.get(parentB.id).get(aggregateResultField));
		System.assertEquals(null, (Decimal) assertParents.get(parentC.id).get(aggregateResultField));

		// Call developer API
		List<SObject> masterRecords = RollupService.rollup(children);

		// Assert nothing has changed on db
		assertParents = new Map<Id, SObject>(Database.query(String.format('select id, {0} from {1}', new List<String>{ aggregateResultField, parentObjectName })));
		System.assertEquals(null, (Decimal) assertParents.get(parentA.id).get(aggregateResultField));
		System.assertEquals(null, (Decimal) assertParents.get(parentB.id).get(aggregateResultField));
		System.assertEquals(null, (Decimal) assertParents.get(parentC.id).get(aggregateResultField));

		// Assert rollups produced
		assertParents = new Map<Id, SObject>(masterRecords);
		System.assertEquals(3, masterRecords.size());
		System.assertEquals(42, (Decimal) assertParents.get(parentA.id).get(aggregateResultField));
		System.assertEquals(42, (Decimal) assertParents.get(parentB.id).get(aggregateResultField));
		System.assertEquals(40, (Decimal) assertParents.get(parentC.id).get(aggregateResultField));
	}

	/**
	 * https://github.com/afawcett/declarative-lookup-rollup-summaries/issues/23
	 */
	private testmethod static void testDateRollupDeleteChild()
	{
		// Test supported?
		if(!TestContext.isSupported())
			return;
		
		// Configure rollup
		LookupRollupSummary__c rollupSummary = new LookupRollupSummary__c();
		rollupSummary.Name = 'Total Opportunities greater than 200 into Annual Revenue on Account';
		rollupSummary.ParentObject__c = 'Account';
		rollupSummary.ChildObject__c = 'Opportunity';
		rollupSummary.RelationShipField__c = 'AccountId';
		rollupSummary.RelationShipCriteria__c = null;
		rollupSummary.FieldToAggregate__c = 'CloseDate';
		rollupSummary.AggregateOperation__c = 'Max';
		rollupSummary.AggregateResultField__c = 'SLAExpirationDate__c';
		rollupSummary.Active__c = true;
		rollupSummary.CalculationMode__c = 'Realtime';
		insert new List<LookupRollupSummary__c> { rollupSummary };
		
		// Test data
		Account account = new Account();
		account.Name = 'Test Account';
		account.AnnualRevenue = 0;
		insert account;
		Opportunity opp = new Opportunity(); 
		opp.Name = 'Test Opportunity';
		opp.StageName = 'Open';
		opp.CloseDate = System.today();
		opp.AccountId = account.Id;
		opp.Amount = 100;
		insert opp;
		
		// Assert rollup
		Id accountId = account.Id;
		System.assertEquals(System.today(), Database.query('select SLAExpirationDate__c from Account where Id = :accountId')[0].get(ACCOUNT_SLA_EXPIRATION_DATE));
		
		// Delete Opportunity
		delete opp;
		
		// Assert rollup
		System.assertEquals(null, Database.query('select SLAExpirationDate__c from Account where Id = :accountId')[0].get(ACCOUNT_SLA_EXPIRATION_DATE));								 	
	}
	
	/**
	 * https://github.com/afawcett/declarative-lookup-rollup-summaries/issues/23
	 */

	private testmethod static void testDateRollupInsertConditionalChild()
	{
		// Test supported?
		if(!TestContext.isSupported())
			return;
		
		// Configure rollup
		LookupRollupSummary__c rollupSummary = new LookupRollupSummary__c();
		rollupSummary.Name = 'Total Opportunities greater than 200 into Annual Revenue on Account';
		rollupSummary.ParentObject__c = 'Account';
		rollupSummary.ChildObject__c = 'Opportunity';
		rollupSummary.RelationShipField__c = 'AccountId';
		rollupSummary.RelationShipCriteria__c = 'CloseDate < TODAY';
		rollupSummary.FieldToAggregate__c = 'CloseDate';
		rollupSummary.AggregateOperation__c = 'Max';
		rollupSummary.AggregateResultField__c = 'SLAExpirationDate__c';
		rollupSummary.Active__c = true;
		rollupSummary.CalculationMode__c = 'Realtime';
		insert new List<LookupRollupSummary__c> { rollupSummary };
		
		// Test data
		Account account = new Account();
		account.Name = 'Test Account';
		account.AnnualRevenue = 0;
		insert account;
		Opportunity opp = new Opportunity(); 
		opp.Name = 'Test Opportunity';
		opp.StageName = 'Open';
		opp.CloseDate = System.today();
		opp.AccountId = account.Id;
		opp.Amount = 100;
		insert opp;
		
		// Assert rollup
		Id accountId = account.Id;
		System.assertEquals(null, Database.query('select SLAExpirationDate__c from Account where Id = :accountId')[0].get(ACCOUNT_SLA_EXPIRATION_DATE));
		
		// Delete Opportunity
		delete opp;
		
		// Assert rollup
		System.assertEquals(null, Database.query('select SLAExpirationDate__c from Account where Id = :accountId')[0].get(ACCOUNT_SLA_EXPIRATION_DATE));								 	
	}
	
	private testmethod static void testRollupWithInAccessibleParent()
	{
		// Test supported?
		if(!TestContext.isSupported())
			return;

		Schema.SObjectType parentType = LookupParent__c.sObjectType;
		Schema.SObjectType childType = LookupChild__c.sObjectType;
		String parentObjectName = parentType.getDescribe().getName();
		String childObjectName = childType.getDescribe().getName();
		String relationshipField = LookupChild__c.LookupParent__c.getDescribe().getName();
		String aggregateField = LookupChild__c.Amount__c.getDescribe().getName();
		String aggregateResultField = LookupParent__c.Total__c.getDescribe().getName();

		// Configure rollup
		LookupRollupSummary__c rollupSummary = new LookupRollupSummary__c();
		rollupSummary.Name = 'Test Rollup';
		rollupSummary.ParentObject__c = parentObjectName;
		rollupSummary.ChildObject__c = childObjectName;
		rollupSummary.RelationShipField__c = relationshipField;
		rollupSummary.FieldToAggregate__c = aggregateField;
		rollupSummary.AggregateOperation__c = RollupSummaries.AggregateOperation.Sum.name();
		rollupSummary.AggregateResultField__c = aggregateResultField;
		rollupSummary.Active__c = true;
		rollupSummary.CalculationMode__c = 'Realtime';
		insert rollupSummary;

		// Insert parents
		SObject parentA = parentType.newSObject();
		parentA.put('Name', 'ParentA');
		insert parentA;

		// Insert children
		SObject child1 = childType.newSObject();
		child1.put(relationshipField, parentA.Id);
		insert child1;

		// Assert rollup
		Map<Id, SObject> assertParents = new Map<Id, SObject>(Database.query(String.format('select id, {0} from {1}', new List<String>{ aggregateResultField, parentObjectName })));
		System.assertEquals(null, (Decimal) assertParents.get(parentA.id).get(aggregateResultField));

		// Create test user
		User testUser = null;
		System.runAs ( new User(Id = UserInfo.getUserId()) ) {
			testUser = createUser();
		}

		// Test data insert children as new user (who cannot see the parent)
		System.runAs(testUser)
		{
			// Ensure this user can read it (the Sharing setting for LookupParent__c is Public Read Only)
			assertParents = new Map<Id, SObject>(Database.query(String.format('select id, {0} from {1}', new List<String>{ aggregateResultField, parentObjectName })));
			System.assertEquals(null, (Decimal) assertParents.get(parentA.id).get(aggregateResultField));

			// Attempt to indirectly via rollup trigger to update parent record
			child1.put(aggregateField, 42);
			update child1;
		}

		// Assert rollup
		assertParents = new Map<Id, SObject>(Database.query(String.format('select id, {0} from {1}', new List<String>{ aggregateResultField, parentObjectName })));
		System.assertEquals(42, (Decimal) assertParents.get(parentA.id).get(aggregateResultField));
	}

	/**
	 * Create test user
	 **/
	private static User createUser()
	{
		// Can only proceed with test if we have a suitable profile
		List<Profile> testProfiles = [Select Id From Profile where Name='Standard User' limit 1];
		if(testProfiles.size()!=1)
			return null; 		

		// Can only proceed with test if we can successfully insert a test user 
		String testUsername = System.now().format('yyyyMMddhhmmss') + '@testorg.com';
		User testUser = new User(Alias = 'test1', Email='testuser1@testorg.com', EmailEncodingKey='UTF-8', LastName='Testing', LanguageLocaleKey='en_US', LocaleSidKey='en_US', ProfileId = testProfiles[0].Id, TimeZoneSidKey='America/Los_Angeles', UserName=testUsername);
		try {
			insert testUser;
			
			// Assign permission sets
			Set<String> psNames = new Set<String> { 'LookupRollupSummariesFull' };
			List<PermissionSet> ps = [select Id from PermissionSet where Name in :psNames];
			insert new List<PermissionSetAssignment> {
				new PermissionSetAssignment(AssigneeId = testUser.Id, PermissionSetId = ps[0].Id)
			};
		} catch (Exception e) {
			return null;
		}		
		return testUser;
	}	
}