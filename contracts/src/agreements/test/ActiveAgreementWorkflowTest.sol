pragma solidity ^0.4.23;

import "commons-base/BaseErrors.sol";
import "commons-base/SystemOwned.sol";
import "commons-utils/DataTypes.sol";
import "commons-utils/TypeUtilsAPI.sol";
import "commons-auth/ParticipantsManager.sol";
import "commons-auth/Organization.sol";
import "commons-auth/UserAccount.sol";
import "commons-auth/DefaultUserAccount.sol";
import "commons-auth/DefaultOrganization.sol";
import "commons-management/DOUG.sol";
import "commons-management/AbstractDbUpgradeable.sol";
import "bpm-model/BpmModel.sol";
import "bpm-model/ProcessModelRepository.sol";
import "bpm-model/ProcessModel.sol";
import "bpm-model/ProcessDefinition.sol";
import "bpm-runtime/BpmRuntime.sol";
import "bpm-runtime/BpmService.sol";
import "bpm-runtime/ProcessInstance.sol"; 
import "bpm-runtime/DefaultProcessInstance.sol"; 
import "bpm-runtime/ApplicationRegistry.sol";

import "agreements/ActiveAgreementRegistry.sol";
import "agreements/DefaultActiveAgreementRegistry.sol";
import "agreements/ArchetypeRegistry.sol";
import "agreements/AgreementSignatureCheck.sol";

contract ActiveAgreementWorkflowTest {

	using TypeUtilsAPI for bytes32;
	using TypeUtilsAPI for bytes;

	string constant EMPTY_STRING = "";

	// test data
	bytes32 activityId1 = "activity1";
	bytes32 activityId2 = "activity2";
	bytes32 activityId3 = "activity3";

	bytes32 user1Id = "iamuser1";
	bytes32 user2Id = "iamuser2";
	bytes32 user3Id = "iamuser3";

	bytes32 appIdSignatureCheck = "AgreementSignatureCheck";

	bytes32 participantId1 = "Participant1";
	bytes32 participantId2 = "Participant2";

	bytes32 departmentId1 = "Dep1";

	address[] parties;
    address[] approvers;

	// tests should overwrite the users and orgs as needed
	Organization org1;
	Organization org2;
	UserAccount userAccount1;
	UserAccount userAccount2;
	UserAccount userAccount3;
	UserAccount nonPartyAccount;


	string constant SUCCESS = "success";
	bytes32 EMPTY = "";
	bytes32 DATA_FIELD_AGREEMENT_PARTIES = "AGREEMENT_PARTIES";

	address[] governingArchetypes;
	address[] governingAgreements;

	// DOUG instance and dependencies retrieved from DOUG
	DOUG doug;
	BpmService bpmService;
	ArchetypeRegistry archetypeRegistry;
	ParticipantsManager participantsManager;
	ProcessModelRepository processModelRepository;
	ApplicationRegistry applicationRegistry;

	// re-usable entities as storage variables to avoid "stack too deep" problems in tests
	TestRegistry agreementRegistry = new TestRegistry();
	ActiveAgreementRegistryDb registryDb = new ActiveAgreementRegistryDb();

	function setDoug(DOUG _doug) external {
		doug = _doug;
		bpmService = BpmService(doug.lookupContract("BpmService"));
		archetypeRegistry = ArchetypeRegistry(doug.lookupContract("ArchetypeRegistry"));
		participantsManager = ParticipantsManager(doug.lookupContract("ParticipantsManager"));
		processModelRepository = ProcessModelRepository(doug.lookupContract("ProcessModelRepository"));
		applicationRegistry = ApplicationRegistry(doug.lookupContract("ApplicationRegistry"));
	}

	/**
	 * @dev Tests the DefaultActiveAgreementRegistry.transferAddressScopes function
	 */
	function testAddressScopeTransfer() external returns (string) {

		// re-usable variables for return values
		uint error;
		address addr;

		// make an agreement with fields of type address and add role qualifiers. Note: archetype is not used, so setting address to 'this'
		ActiveAgreement agreement = new DefaultActiveAgreement(this, "RoleQualifierAgreement", this, EMPTY, EMPTY, false, parties, governingAgreements);
		agreement.setDataValueAsBytes32("AgreementRoleField43", "SellerRole");
		// Adding two scopes to the agreement:
		// 1. Buyer context: a fixed scope for the msg.sender
		// 2. Seller context: a conditional scope for this test address
		agreement.setAddressScope(msg.sender, "Buyer", "BuyerRole", EMPTY, EMPTY, 0x0);
		agreement.setAddressScope(address(this), "Seller", EMPTY, "AgreementRoleField43", EMPTY, 0x0);

		// make a model with participants that point to fields on the agreement
		ProcessModel pm;
		(error, addr) = processModelRepository.createProcessModel("RoleQualifiers", "Role Qualifiers", [1,0,0], this, false, EMPTY, EMPTY);
		if (addr == 0x0) return "Unable to create a ProcessModel";
		pm = ProcessModel(addr);
		pm.addParticipant(participantId1, 0x0, "Buyer", agreementRegistry.DATA_ID_AGREEMENT(), 0x0);
		pm.addParticipant(participantId2, 0x0, "Seller", agreementRegistry.DATA_ID_AGREEMENT(), 0x0);
		// make a ProcessDefinition with activities that use the participants
		(error, addr) = pm.createProcessDefinition("RoleQualifierProcess");
		if (addr == 0x0) return "Unable to create process definition";
		ProcessDefinition pd = ProcessDefinition(addr);
		error = pd.createActivityDefinition(activityId1, BpmModel.ActivityType.TASK, BpmModel.TaskType.USER, BpmModel.TaskBehavior.SENDRECEIVE, participantId1, false, EMPTY, EMPTY, EMPTY);
		error = pd.createActivityDefinition(activityId2, BpmModel.ActivityType.TASK, BpmModel.TaskType.NONE, BpmModel.TaskBehavior.SEND, EMPTY, false, EMPTY, EMPTY, EMPTY);
		error = pd.createActivityDefinition(activityId3, BpmModel.ActivityType.TASK, BpmModel.TaskType.USER, BpmModel.TaskBehavior.SENDRECEIVE, participantId2, false, EMPTY, EMPTY, EMPTY);
		pd.createTransition(activityId1, activityId2);
		pd.createTransition(activityId2, activityId3);
		(bool valid, bytes32 errorMsg) = pd.validate();
		if (!valid) return errorMsg.toString();

		// create a PI with agreement
		ProcessInstance pi = new DefaultProcessInstance(pd, this, EMPTY);
		pi.setDataValueAsAddress(agreementRegistry.DATA_ID_AGREEMENT(), address(agreement));

		// function under test
		agreementRegistry.transferAddressScopes(pi);

		bytes32[] memory newKeys = pi.getAddressScopeKeys();
		if (newKeys.length != 2) return "There should be 2 address scopes on the PI after transfer";
		// test if activity IDs were tagged correctly with address scopes. Activity1 is the Buyer, Activity2 the Seller
		if (pi.resolveAddressScope(msg.sender, activityId1, pi) != "BuyerRole") return "Scope for msg.sender on activity1 not correct after transfer to PI";
		( , , , addr) = pi.getAddressScopeDetails(address(this), activityId3);
		if (addr != address(agreement)) return "The ConditionalData of the address scope for activity3 should've been transformed to use the address of the agreement";
		if (pi.resolveAddressScope(address(this), activityId3, pi) != "SellerRole") return "Scope for address(this) on activity3 not correct after transfer to PI";

		return SUCCESS;
	}

	/**
	 * Tests a typical AN workflow with a multi-instance signing activity that produces an executed agreement
	 */
	function testExecutedAgreementWorkflow() external returns (string) {

		// re-usable variables for return values
		uint error;
		address addr;
		bool success;
		bytes memory returnData;
		bytes32 errorMsg;
		uint8 state;
		ProcessDefinition formationPD;
		ProcessDefinition executionPD;
	
		// service / test setup
		agreementRegistry = new TestRegistry();
		registryDb = new ActiveAgreementRegistryDb();
		SystemOwned(registryDb).transferSystemOwnership(agreementRegistry);
		AbstractDbUpgradeable(agreementRegistry).acceptDatabase(registryDb);
		agreementRegistry.setBpmService(bpmService);

		TestSignatureCheck signatureCheckApp = new TestSignatureCheck();
		applicationRegistry.addApplication("AgreementSignatureCheck", BpmModel.ApplicationType.WEB, signatureCheckApp, bytes4(EMPTY), EMPTY);

		//
		// ORGS/USERS
		//
		// create additional users via constructor
		userAccount1 = new DefaultUserAccount(user1Id, this, address(0));
		userAccount2 = new DefaultUserAccount(user2Id, this, address(0));
		userAccount3 = new DefaultUserAccount(user3Id, this, address(0));
		nonPartyAccount = new DefaultUserAccount("jane.doe", this, address(0));

		org1 = new DefaultOrganization(approvers, EMPTY_STRING);
		org2 = new DefaultOrganization(approvers, EMPTY_STRING);
		org1.addUserToDepartment(userAccount2, EMPTY);
		org2.addDepartment(departmentId1, "Department 1");
		if (!org2.addUserToDepartment(userAccount3, departmentId1)) return "Failed to add user3 to department1";

		delete parties;
		// the parties to the agreement are: one user, one org, and one org with department scope
		parties.push(address(userAccount1));
		parties.push(address(org1));
		parties.push(address(org2));

		//
		// BPM
		//
		ProcessModel pm;
		(error, addr) = processModelRepository.createProcessModel("AN-Model", "AN Model", [1,0,0], userAccount1, false, EMPTY, EMPTY);
		if (addr == 0x0) return "Unable to create a ProcessModel";
		pm = ProcessModel(addr);
		pm.addParticipant(participantId1, 0x0, DATA_FIELD_AGREEMENT_PARTIES, agreementRegistry.DATA_ID_AGREEMENT(), 0x0);
		// Formation Process
		(error, addr) = pm.createProcessDefinition("FormationProcess");
		if (addr == 0x0) return "Unable to create FormationProcess definition";
		formationPD = ProcessDefinition(addr);
		error = formationPD.createActivityDefinition(activityId1, BpmModel.ActivityType.TASK, BpmModel.TaskType.USER, BpmModel.TaskBehavior.SENDRECEIVE, participantId1, true, appIdSignatureCheck, EMPTY, EMPTY);
		if (error != BaseErrors.NO_ERROR()) return "Error creating USER task for formation process definition";
		formationPD.createDataMapping(activityId1, BpmModel.Direction.IN, "agreement", "agreement", EMPTY, 0x0);
		(success, errorMsg) = formationPD.validate();
		if (!success) return errorMsg.toString();
		// Execution Process
		(error, addr) = pm.createProcessDefinition("ExecutionProcess");
		if (addr == 0x0) return "Unable to create ExecutionProcess definition";
		executionPD = ProcessDefinition(addr);
		error = executionPD.createActivityDefinition(activityId1, BpmModel.ActivityType.TASK, BpmModel.TaskType.NONE, BpmModel.TaskBehavior.SEND, EMPTY, false, EMPTY, EMPTY, EMPTY);
		if (error != BaseErrors.NO_ERROR()) return "Error creating SERVICE task for execution process definition";
		(success, errorMsg) = executionPD.validate();
		if (!success) return errorMsg.toString();

		//
		// ARCHETYPE
		//
		addr = archetypeRegistry.createArchetype(10, false, true, "TestArchetype", this, "description", formationPD, executionPD, EMPTY, governingArchetypes);
		if (addr == 0x0) return "Error creating TestArchetype, address is empty";

		//
		// AGREEMENT
		//
		address agreement = agreementRegistry.createAgreement(addr, "TestAgreement", this, EMPTY, EMPTY, false, parties, EMPTY, governingAgreements);
		// Org2 has a department, so we're setting the additional context on the agreement
		ActiveAgreement(agreement).setAddressScope(address(org2), DATA_FIELD_AGREEMENT_PARTIES, departmentId1, EMPTY, EMPTY, 0x0);
		//TODO we currently don't support a negotiation phase in the AN, so the agreement's prose contract is already formulated when the agreement is created.
		if (ActiveAgreement(agreement).getLegalState() != uint8(Agreements.LegalState.FORMULATED)) return "The agreement should be in FORMULATED state";

		//
		// FORMATION / EXECUTION
		//
		if (bpmService.getNumberOfProcessInstances() != 0) return "here should be 0 PIs in the system at test start";
		(error, addr) = agreementRegistry.startFormation(ActiveAgreement(agreement));
		if (error != BaseErrors.NO_ERROR()) return "Error starting the formation on agreement";
		if (ActiveAgreement(agreement).getLegalState() != uint8(Agreements.LegalState.FORMULATED)) return "The agreement should be in FORMULATED state";

		ProcessInstance pi;
		if (bpmService.getNumberOfProcessInstances() != 1) return "There should be 1 PI in the system after agreement formation start";
		if (bpmService.getBpmServiceDb().getNumberOfActivityInstances() != 3) return "There should be 3 AIs total";
		pi = ProcessInstance(bpmService.getProcessInstanceAtIndex(0));
		if (pi.getState() != uint8(BpmRuntime.ProcessInstanceState.ACTIVE)) return "The Formation PI should be active";
		( , , , addr, , state) = pi.getActivityInstanceData(pi.getActivityInstanceAtIndex(0));
		if (state != uint8(BpmRuntime.ActivityInstanceState.SUSPENDED)) return "Activity1 in Formation Process should be suspended";
		if (addr != address(userAccount1)) return "userAccount1 should be the performer of activity1";

		// the agreement should NOT be available as IN data via the application at this point since the user is still the performer!
		if (address(signatureCheckApp).call(keccak256(abi.encodePacked("getInDataAgreement(bytes32)")), pi.getActivityInstanceAtIndex(0)))
			return "Retrieving IN data via the application should REVERT while the user is still the performer";

		// test fail on invalid user
		(success , returnData) = nonPartyAccount.forwardCall(address(pi), abi.encodeWithSignature("completeActivity(bytes32,address)", pi.getActivityInstanceAtIndex(0), bpmService));
		if (returnData.toUint() != BaseErrors.INVALID_ACTOR()) return "Attempting to complete the Sign activity with an unassigned user should fail.";
		( , , , , , state) = pi.getActivityInstanceData(pi.getActivityInstanceAtIndex(0));
		if (state != uint8(BpmRuntime.ActivityInstanceState.SUSPENDED)) return "Activity1 in Formation Process should still be suspended after wrong user attempt";
		// test fail on unsigned agreement
		( , returnData) = userAccount1.forwardCall(address(pi), abi.encodeWithSignature("completeActivity(bytes32,address)", pi.getActivityInstanceAtIndex(0), bpmService));
		if (returnData.toUint() != BaseErrors.RUNTIME_ERROR()) return "Attempting to complete the Sign activity without signing the agreement should fail";
		( , , , addr, , state) = pi.getActivityInstanceData(pi.getActivityInstanceAtIndex(0));
		if (state != uint8(BpmRuntime.ActivityInstanceState.SUSPENDED)) return "Activity1 in Formation Process should still be suspended after completion attempt without signing";
		if (addr != address(userAccount1)) return "userAccount1 should still be the performer of activity1 even after completion failed";

		// test successful completion
		userAccount1.forwardCall(address(agreement), abi.encodeWithSignature("sign()"));
		(success, ) = userAccount1.forwardCall(address(pi), abi.encodeWithSignature("completeActivity(bytes32,address)", pi.getActivityInstanceAtIndex(0), bpmService));
		if (!success) return "Unexpected error attempting to complete Activity1 in Formation Process by user1";
		( , , , , , state) = pi.getActivityInstanceData(pi.getActivityInstanceAtIndex(0));
		if (state != uint8(BpmRuntime.ActivityInstanceState.COMPLETED)) return "ActivityInstance 1 in Formation Process should be completed";

		// verify that the signature app had access to the agreement data mapping
		if (signatureCheckApp.lastAgreement() != address(agreement)) return "The agreement should've been processed by the TestSignatureCheck app.";

		// complete the missing signatures and tasks
		userAccount2.forwardCall(address(agreement), abi.encodeWithSignature("sign()"));
		(success, ) = userAccount2.forwardCall(address(pi), abi.encodeWithSignature("completeActivity(bytes32,address)", pi.getActivityInstanceAtIndex(1), bpmService));
		if (!success) return "Unexpected error attempting to complete Activity1 in Formation Process by user2 in org1";
		( , , , , , state) = pi.getActivityInstanceData(pi.getActivityInstanceAtIndex(1));
		if (state != uint8(BpmRuntime.ActivityInstanceState.COMPLETED)) return "ActivityInstance 2 in Formation Process should be completed";

		userAccount3.forwardCall(address(agreement), abi.encodeWithSignature("sign()"));

		( , , ,addr , , ) = pi.getActivityInstanceData(pi.getActivityInstanceAtIndex(2));
		if (addr != address(org2)) return "ActivityInstance3 should have org2 as performer";
		if (pi.resolveAddressScope(address(org2), activityId1, pi) != departmentId1) return "Org2 in context of activity1 should show the additional department scope";
		// check upfront if the user/org/department context is authorized which is used in the following activity completion
		if (!org2.authorizeUser(userAccount3, departmentId1)) return "User3 should be authorized for dep1 in org2";
		(success, ) = userAccount3.forwardCall(address(pi), abi.encodeWithSignature("completeActivity(bytes32,address)", pi.getActivityInstanceAtIndex(2), bpmService));
		if (!success) return "Unexpected error attempting to complete Activity1 in Formation Process by user3 in org2";
		( , , , , , state) = pi.getActivityInstanceData(pi.getActivityInstanceAtIndex(2));
		if (state != uint8(BpmRuntime.ActivityInstanceState.COMPLETED)) return "ActivityInstance 3 in Formation Process should be completed";

		// AIs 1-3 should all be completed now and the process has moved into execution
		if (bpmService.getNumberOfProcessInstances() != 2) return "There should be 2 PIs in the system after agreement formation is completed";
		if (bpmService.getBpmServiceDb().getNumberOfActivityInstances() != 4) return "There should be 4 AIs total";
		pi = ProcessInstance(bpmService.getProcessInstanceAtIndex(1));
		if (pi.getState() != uint8(BpmRuntime.ProcessInstanceState.COMPLETED)) return "The Execution PI should be completed";
		if (ActiveAgreement(agreement).getLegalState() != uint8(Agreements.LegalState.FULFILLED)) return "The agreement should be in FULFILLED state";

		return SUCCESS;
	}

	/**
	 * Tests workflow handling where the agreement gets cancelled during formation as well as execution.
	 */
	function testCanceledAgreementWorkflow() external returns (string) {

		// re-usable variables for return values
		uint error;
		address addr;
		bool valid;
		bytes32 errorMsg;
		ProcessDefinition formationPD;
		ProcessDefinition executionPD;
		uint numberOfPIs;
	
		// service / test setup
		agreementRegistry = new TestRegistry();
		registryDb = new ActiveAgreementRegistryDb();
		SystemOwned(registryDb).transferSystemOwnership(agreementRegistry);
		AbstractDbUpgradeable(agreementRegistry).acceptDatabase(registryDb);
		agreementRegistry.setBpmService(bpmService);

		userAccount1 = new DefaultUserAccount(user1Id, this, address(0));
		userAccount2 = new DefaultUserAccount(user2Id, this, address(0));
		delete parties;
		parties.push(userAccount1);
		parties.push(userAccount2);

		//
		// BPM
		//
		ProcessModel pm;
		(error, addr) = processModelRepository.createProcessModel("Cancellation-Model", "Cancellation Model", [1,0,0], userAccount1, false, EMPTY, EMPTY);
		if (addr == 0x0) return "Unable to create a ProcessModel";
		pm = ProcessModel(addr);
		// Formation Process
		(error, addr) = pm.createProcessDefinition("FormationProcess");
		if (addr == 0x0) return "Unable to create FormationProcess definition";
		formationPD = ProcessDefinition(addr);
		error = formationPD.createActivityDefinition(activityId1, BpmModel.ActivityType.TASK, BpmModel.TaskType.NONE, BpmModel.TaskBehavior.RECEIVE, EMPTY, false, EMPTY, EMPTY, EMPTY);
		if (error != BaseErrors.NO_ERROR()) return "Error creating NONE task for formation process definition";
		(valid, errorMsg) = formationPD.validate();
		if (!valid) return errorMsg.toString();
		// Execution Process
		(error, addr) = pm.createProcessDefinition("ExecutionProcess");
		if (addr == 0x0) return "Unable to create ExecutionProcess definition";
		executionPD = ProcessDefinition(addr);
		error = executionPD.createActivityDefinition(activityId1, BpmModel.ActivityType.TASK, BpmModel.TaskType.NONE, BpmModel.TaskBehavior.RECEIVE, EMPTY, false, EMPTY, EMPTY, EMPTY);
		if (error != BaseErrors.NO_ERROR()) return "Error creating SERVICE task for execution process definition";
		(valid, errorMsg) = executionPD.validate();
		if (!valid) return errorMsg.toString();

		//
		// ARCHETYPE
		//
		addr = archetypeRegistry.createArchetype(10, false, true, "TestArchetype", this, "description", formationPD, executionPD, EMPTY, governingArchetypes);
		if (addr == 0x0) return "Error creating TestArchetype, address is empty";

		//
		// AGREEMENT
		//
		address agreement1;
		address agreement2;
		agreement1 = agreementRegistry.createAgreement(addr, "TestAgreement1", this, EMPTY, EMPTY, false, parties, EMPTY, governingAgreements);
		if (agreement1 == 0x0) return "Unexpected error creating agreement1";
		agreement2 = agreementRegistry.createAgreement(addr, "TestAgreement2", this, EMPTY, EMPTY, false, parties, EMPTY, governingAgreements);
		if (agreement2 == 0x0) return "Unexpected error creating agreement2";

		//
		// FORMATION / EXECUTION
		//
		numberOfPIs = bpmService.getNumberOfProcessInstances();
		ProcessInstance[3] memory pis; // to collect the created PIs
		(error, addr) = agreementRegistry.startFormation(ActiveAgreement(agreement1));
		if (error != BaseErrors.NO_ERROR()) return "Error starting the formation process 1 on agreement1";
		pis[0] = ProcessInstance(addr);
		if (agreementRegistry.getTrackedFormationProcess(agreement1) == 0x0) return "There should be a tracked formation process for agreement1";
		if (agreementRegistry.getTrackedExecutionProcess(agreement1) != 0x0) return "There should be NO tracked execution process for agreement1";
		if (agreementRegistry.getTrackedFormationProcess(agreement1) != address(pis[0])) return "The tracked formation process should match the started formation PI for agreement1";
		(error, addr) = agreementRegistry.startFormation(ActiveAgreement(agreement2));
		if (error != BaseErrors.NO_ERROR()) return "Error starting the formation process 2 on agreement2";
		pis[1] = ProcessInstance(addr);
		if (agreementRegistry.getTrackedFormationProcess(agreement2) == 0x0) return "There should be a tracked formation process for agreement2";
		if (agreementRegistry.getTrackedExecutionProcess(agreement2) != 0x0) return "There should be NO tracked execution process for agreement2";
		if (agreementRegistry.getTrackedFormationProcess(agreement2) != address(pis[1])) return "The tracked formation process should match the started formation PI for agreement2";

		// sign agreement2 and move PI2 into execution phase
		userAccount1.forwardCall(address(agreement2), abi.encodeWithSignature("sign()"));
		userAccount2.forwardCall(address(agreement2), abi.encodeWithSignature("sign()"));
		if (ActiveAgreement(agreement2).getLegalState() != uint8(Agreements.LegalState.EXECUTED)) return "The agreement2 should be in EXECUTED after signing";
		error = pis[1].completeActivity(pis[1].getActivityInstanceAtIndex(0), bpmService);
		if (error != BaseErrors.NO_ERROR()) return "Error completing wait activity in formation process 2";
	
		if (bpmService.getNumberOfProcessInstances() != numberOfPIs+3) return "There should be 3 additional PIs in the system";
		numberOfPIs = bpmService.getNumberOfProcessInstances();
		// the last added PI should be the execution process of agreement2
		pis[2] = ProcessInstance(bpmService.getProcessInstanceAtIndex(numberOfPIs-1));
		if (agreementRegistry.getTrackedExecutionProcess(agreement2) == 0x0) return "There should now be a tracked execution process for agreement2 after signing";
		if (agreementRegistry.getTrackedExecutionProcess(agreement2) != address(pis[2])) return "The tracked execution process for agreement2 should match the last PI";
		if (pis[0].getState() != uint8(BpmRuntime.ProcessInstanceState.ACTIVE)) return "The Formation PI for agreement1 should be active";
		if (pis[1].getState() != uint8(BpmRuntime.ProcessInstanceState.COMPLETED)) return "The Formation PI for agreement2 should be completed";
		if (pis[2].getState() != uint8(BpmRuntime.ProcessInstanceState.ACTIVE)) return "The Execution PI for agreement2 should be active";

		// cancel the first agreement BEFORE its execution phase (uni-lateral cancellation)
		userAccount2.forwardCall(address(agreement1), abi.encodeWithSignature("cancel()"));
		if (ActiveAgreement(agreement1).getLegalState() != uint8(Agreements.LegalState.CANCELED)) return "agreement1 should be CANCELED";
		if (pis[0].getState() != uint8(BpmRuntime.ProcessInstanceState.ABORTED)) return "The Formation PI for agreement1 should be aborted after canceling";
		
		// cancel the second agreement AFTER it reaches execution phase (multi-lateral cancellation required)
		userAccount2.forwardCall(address(agreement2), abi.encodeWithSignature("cancel()"));
		if (pis[1].getState() != uint8(BpmRuntime.ProcessInstanceState.COMPLETED)) return "The Formation PI for agreement2 should still be completed after 1st cancellation";
		if (pis[2].getState() != uint8(BpmRuntime.ProcessInstanceState.ACTIVE)) return "The Formation PI for agreement2 should still be active after 1st cancellation";
		userAccount1.forwardCall(address(agreement2), abi.encodeWithSignature("cancel()"));
		if (pis[1].getState() != uint8(BpmRuntime.ProcessInstanceState.COMPLETED)) return "The Formation PI for agreement2 should still be completed after 2nd cancellation";
		if (pis[2].getState() != uint8(BpmRuntime.ProcessInstanceState.ABORTED)) return "The Formation PI for agreement2 should be aborted after 2nd cancellation";

		return SUCCESS;
	}

}

/**
 * @dev ActiveAgreementRegistry that exposes internal structures and functions for testing
 */
contract TestRegistry is DefaultActiveAgreementRegistry {

	function getTrackedFormationProcess(address _agreement) public view returns (address) {
		return ActiveAgreementRegistryDb(database).getAgreementFormationProcess(_agreement);
	}

	function getTrackedExecutionProcess(address _agreement) public view returns (address) {
		return ActiveAgreementRegistryDb(database).getAgreementExecutionProcess(_agreement);
	}

	function setBpmService(BpmService _bpmService) external {
		bpmService = _bpmService;
	}
}

contract TestSignatureCheck is AgreementSignatureCheck {

	address public lastAgreement;

	function complete(address _pi, bytes32 _aiId, bytes32 _aId, address _txPerformer) public {
		lastAgreement = ProcessInstance(_pi).getActivityInDataAsAddress(_aiId, "agreement");
		super.complete(_pi, _aiId, _aId, _txPerformer);
	}

}
