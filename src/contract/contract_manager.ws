
/**
 * Summary of the whole Contract system:
 *  - An errand injector adds a notice to every noticeboard in the game
 *  - When the errand is picked, it notifies the ContractManager which
 *    displays a list of contracts the user can start.
 *  - There is a limited amount of contracts per hour (by default)
 *  - For contracts to be restricted per noticeboard, the noticeboards as
 *    well as the contract have a unique identifier.
 *  - These identifiers are used to determine if the same contract was
 *    already completed from the same noticeboard.
 *  - When a contract is started, it selects a random location in the
 *    world, as well a random reward and a random species.
 *  - Every thing random in contracts are generated from a seeded RNG
 *  - The seed is obtained from the noticeboard and the current
 *    generation time.
 *  - Contracts do not persist in the save, but are regenerated every
 *    the player is nearby.
 *  - The available rewards depend on the region and also on the
 *    noticeboard.
 */
statemachine class RER_ContractManager {
  var master: CRandomEncounters;

  function init(_master: CRandomEncounters) {
    this.master = _master;

    this.GotoState('Waiting');
  }

  function pickedContractNoticeFromNoticeboard(errand_name: string) {
    this.GotoState('DialogChoice');
  }

  public function getGenerationTime(time: int): RER_GenerationTime {
    var required_time_elapsed: float;

    required_time_elapsed = StringToFloat(
      theGame.GetInGameConfigWrapper()
      .GetVarValue('RERcontracts', 'RERhoursBeforeNewContracts')
    );

    return RER_GenerationTime(time / required_time_elapsed);
  }

  public function isItTimeToRegenerateContracts(generation_time: RER_GenerationTime): bool {
    return this.master.storages.contract.last_generation_time.time != generation_time.time;
  }

  public function updateStorageGenerationTime(generation_time: RER_GenerationTime) {
    this.master.storages.contract.last_generation_time = generation_time;
    this.master.storages.contract.completed_contracts.Clear();
    this.master.storages.contract.save();
  }

  public function isContractInStorageCompletedContracts(contract: RER_ContractIdentifier): bool {
    var i: int;

    for (i = 0; i < this.master.storages.contract.completed_contracts.Size(); i += 1) {
      if (this.master.storages.contract.completed_contracts[i].identifier == contract.identifier) {
        return true;
      }
    }

    return false;
  }

  public function getUniqueIdFromNoticeboard(noticeboard: W3NoticeBoard): RER_NoticeboardIdentifier {
    var position: Vector;
    var heading: float;
    var uuid: string;

    position = noticeboard.GetWorldPosition();
    heading = noticeboard.GetHeading();

    uuid += RoundF(position.X) + "-";
    uuid += RoundF(position.Y) + "-";
    uuid += RoundF(position.Z) + "-";
    uuid += RoundF(heading);

    return RER_NoticeboardIdentifier(uuid);
  }

  public function getUniqueIdFromContract(noticeboard: RER_NoticeboardIdentifier, distance: RER_ContractDistance, difficulty: int, species: RER_SpeciesTypes, generation_time: RER_GenerationTime): RER_ContractIdentifier {
    var uuid: string;

    uuid += noticeboard.identifier + "-";
    uuid += RoundF(generation_time.time) + "-";
    uuid += 100 + (int)distance + "-";
    uuid += 10 + (int)difficulty + "-";
    uuid += (int)species;

    return RER_ContractIdentifier(uuid);
  }

  public function generateContract(data: RER_ContractGenerationData): RER_ContractRepresentation {
    var contract: RER_ContractRepresentation;
    var bestiary_entry: RER_BestiaryEntry;
    var rng: RandomNumberGenerator;

    contract = RER_ContractRepresentation();
    rng = (new RandomNumberGenerator in this).setSeed(data.rng_seed)
      .useSeed(true);

    contract.identifier = data.identifier;
    contract.destination_point = this.getRandomDestinationAroundPoint(data.starting_point, data.distance, rng);
    contract.destination_radius = 100;

    bestiary_entry = this.master.bestiary.getRandomEntryFromSpeciesType(data.species, rng);
    contract.creature_type = bestiary_entry.type;
    contract.difficulty = data.difficulty;
    contract.region_name = data.region_name;
    contract.rng_seed = data.rng_seed;
    contract.reward_type = RER_getAllowedContractRewardsMaskFromRegion()
                         | RER_getRandomAllowedRewardType(this, data.noticeboard_identifier);

    NLOG("generateContract, reward_type = " + contract.reward_type);

    if (data.difficulty == ContractDifficulty_EASY || data.difficulty == ContractDifficulty_MEDIUM) {
      if (rng.nextRange(10, 0) < 5) {
        contract.event_type = ContractEventType_HORDE;
      }
      else {
        contract.event_type = ContractEventType_NEST;
      }
    }
    else {
      contract.event_type = ContractEventType_BOSS;
    }

    return contract;
  }

  public function getRandomDestinationAroundPoint(starting_point: Vector, distance: RER_ContractDistance, rng: RandomNumberGenerator): Vector {
    var closest_points: array<Vector>;
    var quarter: int;
    var half: int;
    var index: int;
    var size: int;

    closest_points = this.getClosestDestinationPoints(starting_point);

    // since it can return less than what we asked for
    size = closest_points.Size();
    quarter = RoundF(size * 0.25);
    if (size <= 0) {
      NDEBUG("ERROR: no available location for contract was found");
    }

    if (distance == ContractDistance_NEARBY) {
      // the first 12.5%
      index = (int)rng.nextRange(RoundF(quarter * 0.5), 0);
    }
    else if (distance == ContractDistance_CLOSE) {
      // the first 25%
      index = (int)rng.nextRange(quarter, 0);
    }
    else {
      // between 25% and 50%
      index = (int)rng.nextRange(quarter * 2, quarter);
    }

    NLOG("getRandomDestinationAroundPoint, " + index + " size = " + size );

    return closest_points[index];
  }

  public function getClosestDestinationPoints(starting_point: Vector): array<Vector> {
    var sorter_data: array<SU_ArraySorterData>;
    var mappins: array<SEntityMapPinInfo>;
    var entities: array<CGameplayEntity>;
    var current_position: Vector;
    var current_distance: float;
    var current_region: string;
    var output: array<Vector>;
    var i: int;

    current_region = AreaTypeToName(theGame.GetCommonMapManager().GetCurrentArea());

    for (i = 0; i < this.master.static_encounter_manager.lucolivier_encounters.Size(); i += 1) {
      if (!this.master.static_encounter_manager.lucolivier_encounters[i].isInRegion(current_region)) {
        continue;
      }

      current_position = this.master.static_encounter_manager.lucolivier_encounters[i].position;
      current_distance = VecDistanceSquared2D(starting_point, current_position);

      sorter_data.PushBack((new RER_ContractLocation in this).init(current_position, current_distance));
    }

    // We use a list of point of interests across the map
    mappins = this.getPointOfInterests();
    for (i = 0; i < mappins.Size(); i += 1) {
      current_position = mappins[i].entityPosition;
      current_distance = VecDistanceSquared2D(starting_point, current_position);

      sorter_data.PushBack((new RER_ContractLocation in this).init(current_position, current_distance));
    }

    // We also fetch entities with a custom tag to support
    // custom point of interests. This can prove useful in
    // new maps from mod who may want to add support for RER
    // contracts
    FindGameplayEntitiesInRange(
      entities,
      thePlayer,
      10000, // range
      500, // maxresults
      'RER_contractPointOfInterest', // tag
    );

    for (i = 0; i < entities.Size(); i += 1) {
      current_position = entities[i].GetWorldPosition();
      current_distance = VecDistanceSquared2D(starting_point, current_position);

      sorter_data.PushBack((new RER_ContractLocation in this).init(current_position, current_distance));
    }

    // we re-use the same variable here
    sorter_data = SU_sortArray(sorter_data);

    for (i = 0; i < sorter_data.Size(); i += 1) {
      output.PushBack(((RER_ContractLocation)sorter_data[i]).position);
    }

    return output;
  }

  private function getPointOfInterests(): array<SEntityMapPinInfo> {
    var output: array<SEntityMapPinInfo>;
    var all_pins: array<SEntityMapPinInfo>;
    var i: int;

    all_pins = theGame.GetCommonMapManager().GetEntityMapPins(theGame.GetWorld().GetDepotPath());

    for (i = 0; i < all_pins.Size(); i += 1) {
      if (all_pins[i].entityType == 'MonsterNest'
       || all_pins[i].entityType == 'InfestedVineyard'
      //  || all_pins[i].entityType == 'PlaceOfPower'
       || all_pins[i].entityType == 'BanditCamp'
       || all_pins[i].entityType == 'BanditCampfire'
       || all_pins[i].entityType == 'BossAndTreasure'
       || all_pins[i].entityType == 'RescuingTown'
       || all_pins[i].entityType == 'DungeonCrawl'
       || all_pins[i].entityType == 'Hideout'
       || all_pins[i].entityType == 'Plegmund'
       || all_pins[i].entityType == 'KnightErrant'
       || all_pins[i].entityType == 'WineContract'
       || all_pins[i].entityType == 'SignalingStake'
       || all_pins[i].entityType == 'MonsterNest'
       || all_pins[i].entityType == 'TreasureHuntMappin'
       || all_pins[i].entityType == 'PointOfInterestMappin'
        // the same pins but with Disabled at the end
       || all_pins[i].entityType == 'MonsterNestDisabled'
       || all_pins[i].entityType == 'InfestedVineyardDisabled'
      //  || all_pins[i].entityType == 'PlaceOfPowerDisabled'
       || all_pins[i].entityType == 'BanditCampDisabled'
       || all_pins[i].entityType == 'BanditCampfireDisabled'
       || all_pins[i].entityType == 'BossAndTreasureDisabled'
       || all_pins[i].entityType == 'RescuingTownDisabled'
       || all_pins[i].entityType == 'DungeonCrawlDisabled'
       || all_pins[i].entityType == 'HideoutDisabled'
       || all_pins[i].entityType == 'PlegmundDisabled'
       || all_pins[i].entityType == 'KnightErrantDisabled'
       || all_pins[i].entityType == 'WineContractDisabled'
       || all_pins[i].entityType == 'SignalingStakeDisabled'
       || all_pins[i].entityType == 'MonsterNestDisabled'
       || all_pins[i].entityType == 'TreasureHuntMappinDisabled'
       || all_pins[i].entityType == 'PointOfInterestMappinDisabled'
       || all_pins[i].entityType == 'PointOfInterestMappinDisabled') {
        output.PushBack(all_pins[i]);
      }
    }

    return output;
  }

  public function completeCurrentContract() {
    var rewards_increase_from_reputation: float;
    var storage: RER_ContractStorage;
    var rng: RandomNumberGenerator;
    var current_reputation: int;
    var rewards_amount: int;
    var token_name: name;

    storage = this.master.storages.contract;

    if (!storage.has_ongoing_contract) {
      return;
    }

    NLOG("completeCurrentContract, uuid = " + storage.ongoing_contract.identifier.identifier);

    storage.completed_contracts.PushBack(storage.ongoing_contract.identifier);
    storage.has_ongoing_contract = false;

    rng = (new RandomNumberGenerator in this).setSeed(storage.ongoing_contract.rng_seed)
      .useSeed(true);

    token_name = RER_contractRewardTypeToItemName(
      RER_getRandomContractRewardTypeFromFlag(storage.ongoing_contract.reward_type, rng)
    );

    NLOG("completeCurrentContract, token_name = " + token_name + " flag = " + storage.ongoing_contract.reward_type);

    rewards_increase_from_reputation = theGame.GetInGameConfigWrapper()
      .GetVarValue('RERcontracts', 'RERcontractsReputationSystemReputationRewardsIncrease'));

    // if the system is disabled, it will put this value to 0
    rewards_increase_from_reputation *= (int)theGame.GetInGameConfigWrapper()
      .GetVarValue('RERcontracts', 'RERcontractsReputationSystemEnabled'));

    current_reputation = this.getNoticeboardReputation(
      storage.ongoing_contract.noticeboard_identifier
    );

    rewards_amount = RoundF(
      ((int)storage.ongoing_contract.difficulty + 1)
      * (1 + current_reputation)
    );

    if (IsNameValid(token_name)) {
      thePlayer.GetInventory().AddAnItem(token_name, rewards_amount);
      thePlayer.DisplayItemRewardNotification(token_name, rewards_amount);
      theSound.SoundEvent("gui_inventory_buy");
      thePlayer.DisplayHudMessage(GetLocStringByKeyExt("rer_contract_finished"));
    }
    else {
      NDEBUG(
        "RER ERROR: the name of the token is not valid [" + token_name + "]." +
        "You can report this issue to the author, preferably with a copy/screenshot of this message." +
        "<br/>Additional information:" +
        "<br/> - seed: " + storage.ongoing_contract.rng_seed +
        "<br/> - reward type: " + storage.ongoing_contract.reward_type +
        "<br/> - identifier: " + storage.ongoing_contract.identifier.identifier
      );
    }

    this.increaseReputationForNoticeboard(
      storage.ongoing_contract.noticeboard_identifier,
      (int)storage.ongoing_contract.difficulty + 1
    );

    storage.save();
  }

  public function increaseReputationForNoticeboard(noticeboard: RER_NoticeboardIdentifier, optional reputation_gain: int) {
    var current_reputation: int;

    if (reputation_gain <= 0) {
      reputation_gain = 1;
    }

    current_reputation = this.getNoticeboardReputation(noticeboard);
    this.setNoticeboardReputation(noticeboard, current_reputation + reputation_gain);
  }

  private function getNoticeboardReputation(noticeboard: RER_NoticeboardIdentifier): int {
    var current_reputation: RER_NoticeboardReputation;
    var output: int;
    var i: int;

    for (i = 0; i < this.master.storages.contract.noticeboards_reputation.Size(); i += 1) {
      current_reputation = this.master.storages.contract.noticeboards_reputation[i];

      if (current_reputation.noticeboard_identifier.identifier != noticeboard.identifier) {
        continue;
      }

      output = this.master.storages.contract.noticeboards_reputation[i].reputation;

      break;
    }

    return output;
  }

  private function setNoticeboardReputation(noticeboard: RER_NoticeboardIdentifier, value: int) {
    var current_reputation: RER_NoticeboardReputation;
    var i: int;

    for (i = 0; i < this.master.storages.contract.noticeboards_reputation.Size(); i += 1) {
      current_reputation = this.master.storages.contract.noticeboards_reputation[i];

      if (current_reputation.noticeboard_identifier.identifier != noticeboard.identifier) {
        continue;
      }

      this.master.storages.contract.noticeboards_reputation[i].reputation = value;

      return;
    }

    this.master.storages.contract.noticeboards_reputation.PushBack(
      RER_NoticeboardReputation(noticeboard, value)
    );
  }

  public function hasRequiredReputationForNoticeboard(noticeboard: RER_NoticeboardIdentifier): bool {
    var vanilla_contracts_requirement: int;
    var reputation_system_enabled: bool;
    var current_reputation: int;

    reputation_system_enabled = theGame.GetInGameConfigWrapper()
      .GetVarValue('RERcontracts', 'RERcontractsReputationSystemEnabled'));

    if (!reputation_system_enabled) {
      return true;
    }

    vanilla_contracts_requirement = theGame.GetInGameConfigWrapper()
      .GetVarValue('RERcontracts', 'RERcontractsReputationSystemVanillaContractsRequirement'));

    current_reputation = this.getNoticeboardReputation(noticeboard);

    return current_reputation >= vanilla_contracts_requirement;
  }

  /**
   * Returns whether the player has the needed reputation for the noticeboard
   * and a contract of the given difficulty.
   */
  public function hasRequiredReputationForContractAtNoticeboard(noticeboard: RER_NoticeboardIdentifier, difficulty: RER_ContractDifficulty): bool {
    var vanilla_contracts_requirement: int;
    var reputation_system_enabled: bool;
    var current_reputation: int;

    reputation_system_enabled = theGame.GetInGameConfigWrapper()
      .GetVarValue('RERcontracts', 'RERcontractsReputationSystemEnabled'));

    if (!reputation_system_enabled) {
      return true;
    }

    vanilla_contracts_requirement = theGame.GetInGameConfigWrapper()
      .GetVarValue('RERcontracts', 'RERcontractsReputationSystemVanillaContractsRequirement'));

    current_reputation = this.getNoticeboardReputation(noticeboard);

    // We use the requirement for the vanilla contracts multiplied by the difficulty.
    // Since the difficulty starts at easy, which is equal to 0 this means easy contracts
    // are always available, then it starts to ramp up at medium.
    return current_reputation >= vanilla_contracts_requirement * (int)difficulty;
  }
}