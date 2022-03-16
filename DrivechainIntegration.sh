#!/bin/bash

# DriveChain integration testing

# This script will download and build the mainchain and all known sidechain
# projects. Then a series of integration tests will run.

#
# Warn user, delete old data, clone repositories
#

# VERSION 2 TODO:
# * Make mining a block & BMM mining functions
#
# * After the first test, repeat the same tests again but with 2 sidechains
# active at the same time.
#
# * Then do some tests sending deposits and creating withdrawals from both
# sidechains. Do a test where a deposit is made to the first sidechain,
# withdrawn, and then sent to the second sidechain and withdrawn again.
#
# * Keep track of balances and make sure that no funds are lost to BMM - make
# sure that 100% of funds from failed BMM txns are recovered
#
# * Test a sidechain withdrawal failing
#
# * Test multiple withdrawals at once for two sidechains
#
VERSION=1

REINDEX=0
BMMAMOUNT=0.0001
MINWORKSCORE=131

# Read arguments
SKIP_CLONE=0 # Skip cloning the repositories from github
SKIP_BUILD=0 # Skip pulling and building repositories
SKIP_CHECK=0 # Skip make check on repositories
SKIP_REPLACE_TIP=0 # Skip tests where we replace the chainActive.Tip()
SKIP_RESTART=0 # Skip tests where we restart and verify state after restart
SKIP_SHUTDOWN=0 # Don't shutdown the main & side clients when finished testing
INCOMPATIBLE_BDB=0 # Compile --with-incompatible-bdb
for arg in "$@"
do
    if [ "$arg" == "--help" ]; then
        echo "The following command line options are available:"
        echo "--skip_clone"
        echo "--skip_build"
        echo "--skip_check"
        echo "--skip_replace_tip"
        echo "--skip_restart"
        echo "--skip_shutdown"
        echo "--with-incompatible-bdb"
        exit
    elif [ "$arg" == "--skip_clone" ]; then
        SKIP_CLONE=1
    elif [ "$arg" == "--skip_build" ]; then
        SKIP_BUILD=1
    elif [ "$arg" == "--skip_check" ]; then
        SKIP_CHECK=1
    elif [ "$arg" == "--skip_replace_tip" ]; then
        SKIP_REPLACE_TIP=1
    elif [ "$arg" == "--skip_restart" ]; then
        SKIP_RESTART=1
    elif [ "$arg" == "--skip_shutdown" ]; then
        SKIP_SHUTDOWN=1
    elif [ "$arg" == "--with-incompatible-bdb" ]; then
        INCOMPATIBLE_BDB=1
    fi
done

clear

echo -e "\e[36m██████╗ ██████╗ ██╗██╗   ██╗███████╗███╗   ██╗███████╗████████╗\e[0m"
echo -e "\e[36m██╔══██╗██╔══██╗██║██║   ██║██╔════╝████╗  ██║██╔════╝╚══██╔══╝\e[0m"
echo -e "\e[36m██║  ██║██████╔╝██║██║   ██║█████╗  ██╔██╗ ██║█████╗     ██║\e[0m"
echo -e "\e[36m██║  ██║██╔══██╗██║╚██╗ ██╔╝██╔══╝  ██║╚██╗██║██╔══╝     ██║\e[0m"
echo -e "\e[36m██████╔╝██║  ██║██║ ╚████╔╝ ███████╗██║ ╚████║███████╗   ██║\e[0m"
echo -e "\e[36m╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═══╝  ╚══════╝╚═╝  ╚═══╝╚══════╝   ╚═╝\e[0m"
echo -e "\e[1mAutomated integration testing script (v$VERSION)\e[0m"
echo
echo "This script will clone, build, configure & run DriveNet and sidechain(s)"
echo "The functional unit tests will be run for DriveNet and sidechain(s)."
echo "If those tests pass, the integration test script will try to go through"
echo "the process of BMM mining, deposit to and withdraw from the sidechain(s)."
echo
echo "We will also restart the software many times to check for issues with"
echo "shutdown and initialization."
echo
echo -e "\e[1mREAD: YOUR DATA DIRECTORIES WILL BE DELETED\e[0m"
echo
echo "Your data directories ex: ~/.drivenet & ~/.testchain and any other"
echo "sidechain data directories will be deleted!"
echo
echo -e "\e[31mWARNING: THIS WILL DELETE YOUR DRIVECHAIN & SIDECHAIN DATA!\e[0m"
echo
echo -e "\e[32mYou should probably run this in a VM\e[0m"
echo
read -p "Are you sure you want to run this? (yes/no): " WARNING_ANSWER
if [ "$WARNING_ANSWER" != "yes" ]; then
    exit
fi

#
# Functions to help the script
#
function startdrivenet {
    if [ $REINDEX -eq 1 ]; then
        echo
        echo "DriveNet will be reindexed"
        echo
        ./mainchain/src/qt/drivenet-qt \
        --reindex \
        --connect=0 \
        --regtest \
        --defaultwithdrawalvote=upvote &
    else
        ./mainchain/src/qt/drivenet-qt \
        --connect=0 \
        --regtest \
        --defaultwithdrawalvote=upvote &
    fi
}

function starttestchain {
    ./sidechains/src/qt/testchain-qt \
    --connect=0 \
    --regtest \
    --verifybmmacceptheader \
    --verifybmmacceptblock \
    --verifybmmreadblock \
    --verifybmmcheckblock \
    --verifywithdrawalbundleacceptblock \
    --minwithdrawal=1 &
}

function restartdrivenet {

    if [ $SKIP_RESTART -eq 1 ]; then
        return 0
    fi

    #
    # Shutdown DriveNet, restart it, and make sure nothing broke.
    # Exits the script if anything did break.
    #
    # TODO check return value of python json parsing and exit if it failed
    # TODO use jq instead of python
    echo
    echo "We will now restart DriveNet & verify its state after restarting!"

    # Record the state before restart
    HASHSCDB=`./mainchain/src/drivenet-cli --regtest getscdbhash`
    HASHSCDB=`echo $HASHSCDB | python -c 'import json, sys; obj=json.load(sys.stdin); print obj["hashscdb"]'`

    HASHSCDBTOTAL=`./mainchain/src/drivenet-cli --regtest gettotalscdbhash`
    HASHSCDBTOTAL=`echo $HASHSCDBTOTAL | python -c 'import json, sys; obj=json.load(sys.stdin); print obj["hashscdbtotal"]'`

    # Count doesn't return a json array like the above commands - so no parsing
    COUNT=`./mainchain/src/drivenet-cli --regtest getblockcount`
    # getbestblockhash also doesn't return an array
    BESTBLOCK=`./mainchain/src/drivenet-cli --regtest getbestblockhash`

    # Restart
    ./mainchain/src/drivenet-cli --regtest stop
    sleep 20s # Wait a little bit incase shutdown takes a while
    startdrivenet

    echo
    echo "Waiting for mainchain to start"
    sleep 20s

    # Verify the state after restart
    HASHSCDBRESTART=`./mainchain/src/drivenet-cli --regtest getscdbhash`
    HASHSCDBRESTART=`echo $HASHSCDBRESTART | python -c 'import json, sys; obj=json.load(sys.stdin); print obj["hashscdb"]'`

    HASHSCDBTOTALRESTART=`./mainchain/src/drivenet-cli --regtest gettotalscdbhash`
    HASHSCDBTOTALRESTART=`echo $HASHSCDBTOTALRESTART | python -c 'import json, sys; obj=json.load(sys.stdin); print obj["hashscdbtotal"]'`

    COUNTRESTART=`./mainchain/src/drivenet-cli --regtest getblockcount`
    BESTBLOCKRESTART=`./mainchain/src/drivenet-cli --regtest getbestblockhash`

    if [ "$COUNT" != "$COUNTRESTART" ]; then
        echo "Error after restarting DriveNet!"
        echo "COUNT != COUNTRESTART"
        echo "$COUNT != $COUNTRESTART"
        exit
    fi
    if [ "$BESTBLOCK" != "$BESTBLOCKRESTART" ]; then
        echo "Error after restarting DriveNet!"
        echo "BESTBLOCK != BESTBLOCKRESTART"
        echo "$BESTBLOCK != $BESTBLOCKRESTART"
        exit
    fi

    if [ "$HASHSCDB" != "$HASHSCDBRESTART" ]; then
        echo "Error after restarting DriveNet!"
        echo "HASHSCDB != HASHSCDBRESTART"
        echo "$HASHSCDB != $HASHSCDBRESTART"
        exit
    fi
    if [ "$HASHSCDBTOTAL" != "$HASHSCDBTOTALRESTART" ]; then
        echo "Error after restarting DriveNet!"
        echo "HASHSCDBTOTAL != HASHSCDBTOTALRESTART"
        echo "$HASHSCDBTOTAL != $HASHSCDBTOTALRESTART"
        exit
    fi

    echo
    echo "DriveNet restart and state check check successful!"
    sleep 3s
}

function replacetip {

    if [ $SKIP_REPLACE_TIP -eq 1 ]; then
        return 0
    fi

    # Disconnect chainActive.Tip() and replace it with a new tip

    echo
    echo "We will now disconnect the chain tip and replace it with a new one!"
    sleep 3s

    OLDCOUNT=`./mainchain/src/drivenet-cli --regtest getblockcount`
    OLDTIP=`./mainchain/src/drivenet-cli --regtest getbestblockhash`
    ./mainchain/src/drivenet-cli --regtest invalidateblock $OLDTIP

    sleep 3s # Give some time for the block to be invalidated

    DISCONNECTCOUNT=`./mainchain/src/drivenet-cli --regtest getblockcount`
    if [ "$DISCONNECTCOUNT" == "$OLDCOUNT" ]; then
        echo "Failed to disconnect tip!"
        exit
    fi

    ./mainchain/src/drivenet-cli --regtest generate 1

    NEWTIP=`./mainchain/src/drivenet-cli --regtest getbestblockhash`
    NEWCOUNT=`./mainchain/src/drivenet-cli --regtest getblockcount`
    if [ "$OLDTIP" == "$NEWTIP" ] || [ "$OLDCOUNT" != "$NEWCOUNT" ]; then
        echo "Failed to replace tip!"
        exit
    else
        echo "Tip replaced!"
        echo "Old tip: $OLDTIP"
        echo "New tip: $NEWTIP"
    fi
}








# Remove old data directories
rm -rf ~/.drivenet
rm -rf ~/.testchain








# These can fail, meaning that the repository is already downloaded
if [ $SKIP_CLONE -ne 1 ]; then
    echo
    echo "Cloning repositories"
    echo "If you see \"Fatal error\" here that means the repository is already cloned - no problem"
    git clone https://github.com/drivechain-project/mainchain
    git clone https://github.com/drivechain-project/sidechains
fi








#
# Build repositories & run their unit tests
#
echo
echo "Building repositories"
cd sidechains
if [ $SKIP_BUILD -ne 1 ]; then
    git checkout testchain &&
    git pull &&
    ./autogen.sh

    if [ $INCOMPATIBLE_BDB -ne 1 ]; then
        ./configure
    else
        ./configure --with-incompatible-bdb
    fi

    if [ $? -ne 0 ]; then
        echo "Configure failed!"
        exit
    fi

    make -j "$(nproc)"

    if [ $? -ne 0 ]; then
        echo "Make failed!"
        exit
    fi
fi

if [ $SKIP_CHECK -ne 1 ]; then
    make check
    if [ $? -ne 0 ]; then
        echo "Make check failed!"
        exit
    fi
fi

cd ../mainchain
if [ $SKIP_BUILD -ne 1 ]; then
    git checkout master &&
    git pull &&
    ./autogen.sh

    if [ $INCOMPATIBLE_BDB -ne 1 ]; then
        ./configure
    else
        ./configure --with-incompatible-bdb
    fi

    if [ $? -ne 0 ]; then
        echo "Configure failed!"
        exit
    fi

    make -j "$(nproc)"

    if [ $? -ne 0 ]; then
        echo "Make failed!"
        exit
    fi
fi

if [ $SKIP_CHECK -ne 1 ]; then
    make check
    if [ $? -ne 0 ]; then
        echo "Make check failed!"
        exit
    fi
fi

cd ../




#
# The testing starts here
#




#
# Get mainchain configured and running. Mine first 100 mainchain blocks.
#

# Create configuration file for mainchain
echo
echo "Create mainchain configuration file"
mkdir ~/.drivenet/
touch ~/.drivenet/drivenet.conf
echo "rpcuser=patrick" > ~/.drivenet/drivenet.conf
echo "rpcpassword=integrationtesting" >> ~/.drivenet/drivenet.conf
echo "server=1" >> ~/.drivenet/drivenet.conf

# Start DriveNet-qt
startdrivenet

echo
echo "Waiting for mainchain to start"
sleep 5s

echo
echo "Checking if the mainchain has started"

# Test that mainchain can receive commands and has 0 blocks
GETINFO=`./mainchain/src/drivenet-cli --regtest getmininginfo`
COUNT=`echo $GETINFO | grep -c "\"blocks\": 0"`
if [ "$COUNT" -eq 1 ]; then
    echo
    echo "Mainchain up and running!"
else
    echo
    echo "ERROR failed to send commands to mainchain or block count non-zero"
    exit
fi

echo
echo "Mainchain will now generate first 100 blocks"
sleep 3s

./mainchain/src/drivenet-cli --regtest generate 100

# Check that 100 blocks were mined
GETINFO=`./mainchain/src/drivenet-cli --regtest getmininginfo`
COUNT=`echo $GETINFO | grep -c "\"blocks\": 100"`
if [ "$COUNT" -eq 1 ]; then
    echo
    echo "Mainchain has mined first 100 blocks"
else
    echo
    echo "ERROR failed to mine first 100 blocks!"
    exit
fi

# Disconnect chain tip, replace with a new one
replacetip

# Shutdown DriveNet, restart it, and make sure nothing broke
REINDEX=0
restartdrivenet








#
# Activate a sidechain
#

# Create a sidechain proposal
./mainchain/src/drivenet-cli --regtest createsidechainproposal 0 "testchain" "testchain for integration test" "0186ff51f527ffdcf2413d50bdf8fab1feb20e5f82815dad48c73cf462b8b313"

# Check that proposal was cached (not in chain yet)
LISTPROPOSALS=`./mainchain/src/drivenet-cli --regtest listsidechainproposals`
COUNT=`echo $LISTPROPOSALS | grep -c "\"title\": \"testchain\""`
if [ "$COUNT" -eq 1 ]; then
    echo
    echo "Sidechain proposal for sidechain testchain has been created!"
else
    echo
    echo "ERROR failed to create testchain sidechain proposal!"
    exit
fi

echo
echo "Will now mine a block so that sidechain proposal is added to the chain"

# Mine one block, proposal should be in chain after that
./mainchain/src/drivenet-cli --regtest generate 1

# Check that we have 101 blocks now
GETINFO=`./mainchain/src/drivenet-cli --regtest getmininginfo`
COUNT=`echo $GETINFO | grep -c "\"blocks\": 101"`
if [ "$COUNT" -eq 1 ]; then
    echo
    echo "Mainchain has 101 blocks now"
else
    echo
    echo "ERROR failed to mine block including sidechain proposal!"
    exit
fi

# Disconnect chain tip, replace with a new one
replacetip

# Shutdown DriveNet, restart it, and make sure nothing broke
REINDEX=0
restartdrivenet

# Check that proposal has been added to the chain and ready for voting
LISTACTIVATION=`./mainchain/src/drivenet-cli --regtest listsidechainactivationstatus`
COUNT=`echo $LISTACTIVATION | grep -c "\"title\": \"testchain\""`
if [ "$COUNT" -eq 1 ]; then
    echo
    echo "Sidechain proposal made it into the chain!"
else
    echo
    echo "ERROR sidechain proposal not in chain!"
    exit
fi
# Check age
COUNT=`echo $LISTACTIVATION | grep -c "\"nage\": 1"`
if [ "$COUNT" -eq 1 ]; then
    echo
    echo "Sidechain proposal age correct!"
else
    echo
    echo "ERROR sidechain proposal age invalid!"
    exit
fi
# Check fail count
COUNT=`echo $LISTACTIVATION | grep -c "\"nfail\": 0"`
if [ "$COUNT" -eq 1 ]; then
    echo
    echo "Sidechain proposal has no failures!"
else
    echo
    echo "ERROR sidechain proposal has failures but should not!"
    exit
fi

# Check that there are currently no active sidechains
LISTACTIVESIDECHAINS=`./mainchain/src/drivenet-cli --regtest listactivesidechains`
if [ "$LISTACTIVESIDECHAINS" == $'[\n]' ]; then
    echo
    echo "Good: no sidechains are active yet"
else
    echo
    echo "ERROR sidechain is already active but should not be!"
    exit
fi

# Shutdown DriveNet, restart it, and make sure nothing broke
REINDEX=0
restartdrivenet

echo
echo "Will now mine enough blocks to activate the sidechain"
sleep 5s

# Mine enough blocks to activate the sidechain
./mainchain/src/drivenet-cli --regtest generate 255

# Check that 255 blocks were mined
GETINFO=`./mainchain/src/drivenet-cli --regtest getmininginfo`
COUNT=`echo $GETINFO | grep -c "\"blocks\": 356"`
if [ "$COUNT" -eq 1 ]; then
    echo
    echo "Mainchain has 356 blocks"
else
    echo
    echo "ERROR failed to mine blocks to activate the sidechain!"
    exit
fi

# Check that the sidechain has been activated
LISTACTIVESIDECHAINS=`./mainchain/src/drivenet-cli --regtest listactivesidechains`
COUNT=`echo $LISTACTIVESIDECHAINS | grep -c "\"title\": \"testchain\""`
if [ "$COUNT" -eq 1 ]; then
    echo
    echo "Sidechain has activated!"
else
    echo
    echo "ERROR sidechain failed to activate!"
    exit
fi

echo
echo "listactivesidechains:"
echo
echo "$LISTACTIVESIDECHAINS"

# Disconnect chain tip, replace with a new one
replacetip

# Shutdown DriveNet, restart it, and make sure nothing broke
REINDEX=0
restartdrivenet






#
# Get sidechain configured and running
#

# Create configuration file for sidechain testchain
echo
echo "Creating sidechain configuration file"
mkdir ~/.testchain/
touch ~/.testchain/testchain.conf
echo "rpcuser=patrick" > ~/.testchain/testchain.conf
echo "rpcpassword=integrationtesting" >> ~/.testchain/testchain.conf
echo "server=1" >> ~/.testchain/testchain.conf

echo
echo "The sidechain testchain will now be started"
sleep 5s

# Start the sidechain and test that it can receive commands and has 0 blocks
starttestchain

echo
echo "Waiting for testchain to start"
sleep 5s

echo
echo "Checking if the sidechain has started"

# Test that sidechain can receive commands and has 0 blocks
GETINFO=`./sidechains/src/testchain-cli --regtest getmininginfo`
COUNT=`echo $GETINFO | grep -c "\"blocks\": 0"`
if [ "$COUNT" -eq 1 ]; then
    echo "Sidechain up and running!"
else
    echo "ERROR failed to send commands to sidechain or block count non-zero"
    exit
fi

# Check if the sidechain can communicate with the mainchain








#
# Start BMM mining the sidechain
#

# The first time that we call this it should create the first BMM request and
# send it to the mainchain node, which will add it to the mempool
echo
echo "Going to refresh BMM on the sidechain and send BMM request to mainchain"
./sidechains/src/testchain-cli --regtest refreshbmm $BMMAMOUNT

# TODO check that mainchain has BMM request in mempool

echo
echo "Giving mainchain some time to receive BMM request from sidechain..."
sleep 3s

echo
echo "Mining block on the mainchain, should include BMM commit"

# Mine a mainchain block, which should include the BMM request we just made
./mainchain/src/drivenet-cli --regtest generate 1

# Check that the block was mined
GETINFO=`./mainchain/src/drivenet-cli --regtest getmininginfo`
COUNT=`echo $GETINFO | grep -c "\"blocks\": 357"`
if [ "$COUNT" -eq 1 ]; then
    echo
    echo "Mainchain has 357 blocks"
else
    echo
    echo "ERROR failed to mine blocks to include first BMM request!"
    exit
fi

# Shutdown DriveNet, restart it, and make sure nothing broke
REINDEX=1
restartdrivenet

# TODO verifiy that bmm request was added to chain and removed from mempool

# Refresh BMM again, this time the block we created the first BMM request for
# should be added to the side chain, and a new BMM request created for the next
# block
echo
echo "Will now refresh BMM on the sidechain again and look for our BMM commit"
echo "BMM block will be connected to the sidechain if BMM commit was made."
./sidechains/src/testchain-cli --regtest refreshbmm $BMMAMOUNT

# Check that BMM block was added to the sidechain
GETINFO=`./sidechains/src/testchain-cli --regtest getmininginfo`
COUNT=`echo $GETINFO | grep -c "\"blocks\": 1"`
if [ "$COUNT" -eq 1 ]; then
    echo "Sidechain connected BMM block!"
else
    echo "ERROR sidechain has no BMM block connected!"
    exit
fi

# Mine some more BMM blocks and make sure that they all make it to the sidechain
echo
echo "Now we will test mining more BMM blocks"

CURRENT_BLOCKS=357
CURRENT_SIDE_BLOCKS=1
COUNTER=1
while [ $COUNTER -le 10 ]
do
    # Wait a little bit
    echo
    echo "Waiting for new BMM request to make it to the mainchain..."
    sleep 0.26s

    echo "Mining mainchain block"
    # Generate mainchain block
    ./mainchain/src/drivenet-cli --regtest generate 1

    CURRENT_BLOCKS=$(( CURRENT_BLOCKS + 1 ))


    # Check that mainchain block was connected
    GETINFO=`./mainchain/src/drivenet-cli --regtest getmininginfo`

    echo $GETINFO
    echo $CURRENT_BLOCKS
    COUNT=`echo $GETINFO | grep -c "\"blocks\": $CURRENT_BLOCKS"`
    if [ "$COUNT" -eq 1 ]; then
        echo
        echo "Mainchain has $CURRENT_BLOCKS blocks"
    else
        echo
        echo "ERROR failed to mine block for bmm!"
        exit
    fi

    # Refresh BMM on the sidechain
    echo
    echo "Refreshing BMM on the sidechain..."
    ./sidechains/src/testchain-cli --regtest refreshbmm $BMMAMOUNT

    CURRENT_SIDE_BLOCKS=$(( CURRENT_SIDE_BLOCKS + 1 ))

    # Check that BMM block was added to the side chain
    GETINFO=`./sidechains/src/testchain-cli --regtest getmininginfo`
    COUNT=`echo $GETINFO | grep -c "\"blocks\": $CURRENT_SIDE_BLOCKS"`
    if [ "$COUNT" -eq 1 ]; then
        echo
        echo "Sidechain connected BMM block!"
    else
        echo
        echo "ERROR sidechain did not connect BMM block!"
        # TODO In the testing environment we shouldn't have any failures at all.
        # It would however be normal in real use to have some failures...
        #
        # For now, if we have a failure during testing which is probably due
        # to a bug on main or side and not the testing environment which has
        # perfect conditions, move on and try again just like a real node would.
        # TODO renable exit here?
        # Subtract 1 before moving on, since we
        # failed to actually add it.
        CURRENT_SIDE_BLOCKS=$(( CURRENT_SIDE_BLOCKS - 1 ))
    fi

    ((COUNTER++))
done





# Shutdown DriveNet, restart it, and make sure nothing broke
REINDEX=0
restartdrivenet





#
# Deposit to the sidechain
#

echo "We will now deposit to the sidechain"
sleep 3s

# Create sidechain deposit
ADDRESS=`./sidechains/src/testchain-cli --regtest getnewaddress sidechain legacy`
DEPOSITADDRESS=`./sidechains/src/testchain-cli --regtest formatdepositaddress $ADDRESS`
./mainchain/src/drivenet-cli --regtest createsidechaindeposit 0 $DEPOSITADDRESS 1 0.01

# Verify that there are currently no deposits in the db
DEPOSITCOUNT=`./mainchain/src/drivenet-cli --regtest countsidechaindeposits 0`
if [ $DEPOSITCOUNT -ne 0 ]; then
    echo "Error: There is already a deposit in the db when there should be 0!"
    exit
else
    echo "Good: No deposits in db yet"
fi

# Generate a block to add the deposit to the mainchain
./mainchain/src/drivenet-cli --regtest generate 1
CURRENT_BLOCKS=$(( CURRENT_BLOCKS + 1 )) # TODO stop using CURRENT_BLOCKS

# Verify that a deposit was added to the db
DEPOSITCOUNT=`./mainchain/src/drivenet-cli --regtest countsidechaindeposits 0`
if [ $DEPOSITCOUNT -ne 1 ]; then
    echo "Error: No deposit was added to the db!"
    exit
else
    echo "Good: Deposit added to db"
fi

# Replace the chain tip and restart
replacetip
REINDEX=0
restartdrivenet

# Verify that a deposit is still in the db after replacing tip & restarting
DEPOSITCOUNT=`./mainchain/src/drivenet-cli --regtest countsidechaindeposits 0`
if [ $DEPOSITCOUNT -ne 1 ]; then
    echo "Error: Deposit vanished after replacing tip & restarting!"
    exit
else
    echo "Good: Deposit still in db after replacing tip & restarting"
fi

# Mine some blocks and BMM the sidechain so it can process the deposit
COUNTER=1
while [ $COUNTER -le 200 ]
do
    # Wait a little bit
    echo
    echo "Waiting for new BMM request to make it to the mainchain..."
    sleep 0.26s

    echo "Mining mainchain block"
    # Generate mainchain block
    ./mainchain/src/drivenet-cli --regtest generate 1

    CURRENT_BLOCKS=$(( CURRENT_BLOCKS + 1 ))

    # Check that mainchain block was connected
    GETINFO=`./mainchain/src/drivenet-cli --regtest getmininginfo`
    COUNT=`echo $GETINFO | grep -c "\"blocks\": $CURRENT_BLOCKS"`
    if [ "$COUNT" -eq 1 ]; then
        echo
        echo "Mainchain has $CURRENT_BLOCKS blocks"
    else
        echo
        echo "ERROR failed to mine block for bmm!"
        exit
    fi

    # Refresh BMM on the sidechain
    echo
    echo "Refreshing BMM on the sidechain..."
    ./sidechains/src/testchain-cli --regtest refreshbmm $BMMAMOUNT

    CURRENT_SIDE_BLOCKS=$(( CURRENT_SIDE_BLOCKS + 1 ))

    # Check that BMM block was added to the side chain
    GETINFO=`./sidechains/src/testchain-cli --regtest getmininginfo`
    COUNT=`echo $GETINFO | grep -c "\"blocks\": $CURRENT_SIDE_BLOCKS"`
    if [ "$COUNT" -eq 1 ]; then
        echo
        echo "Sidechain connected BMM block!"
    else
        echo
        echo "ERROR sidechain did not connect BMM block!"
        CURRENT_SIDE_BLOCKS=$(( CURRENT_SIDE_BLOCKS - 1 ))
    fi

    ((COUNTER++))
done

# Check if the deposit address has any transactions on the sidechain
LIST_TRANSACTIONS=`./sidechains/src/testchain-cli --regtest listtransactions "sidechain"`
COUNT=`echo $LIST_TRANSACTIONS | grep -c "\"address\": \"$ADDRESS\""`
if [ "$COUNT" -ge 1 ]; then
    echo
    echo "Sidechain deposit address has transactions!"
else
    echo
    echo "ERROR sidechain did not receive deposit!"
    exit
fi

# Check for the deposit amount
COUNT=`echo $LIST_TRANSACTIONS | grep -c "\"amount\": 0.99999000"`
if [ "$COUNT" -eq 1 ]; then
    echo
    echo "Sidechain received correct deposit amount!"
else
    echo
    echo "ERROR sidechain did not receive deposit!"
    exit
fi

# Shutdown DriveNet, restart it, and make sure nothing broke
REINDEX=0
restartdrivenet

echo
echo "Now we will BMM the sidechain until the deposit has matured!"

# Sleep here so user can read the deposit debug output
sleep 5s

# Mature the deposit on the sidechain, so that it can be withdrawn
COUNTER=1
while [ $COUNTER -le 121 ]
do
    # Wait a little bit
    echo
    echo "Waiting for new BMM request to make it to the mainchain..."
    sleep 0.26s

    echo "Mining mainchain block"
    # Generate mainchain block
    ./mainchain/src/drivenet-cli --regtest generate 1

    CURRENT_BLOCKS=$(( CURRENT_BLOCKS + 1 ))

    # Check that mainchain block was connected
    GETINFO=`./mainchain/src/drivenet-cli --regtest getmininginfo`
    COUNT=`echo $GETINFO | grep -c "\"blocks\": $CURRENT_BLOCKS"`
    if [ "$COUNT" -eq 1 ]; then
        echo
        echo "Mainchain has $CURRENT_BLOCKS blocks"
    else
        echo
        echo "ERROR failed to mine block to mature deposit!"
        exit
    fi

    # Refresh BMM on the sidechain
    echo
    echo "Refreshing BMM on the sidechain..."
    ./sidechains/src/testchain-cli --regtest refreshbmm $BMMAMOUNT

    CURRENT_SIDE_BLOCKS=$(( CURRENT_SIDE_BLOCKS + 1 ))

    # Check that BMM block was added to the side chain
    GETINFO=`./sidechains/src/testchain-cli --regtest getmininginfo`
    COUNT=`echo $GETINFO | grep -c "\"blocks\": $CURRENT_SIDE_BLOCKS"`
    if [ "$COUNT" -eq 1 ]; then
        echo
        echo "Sidechain connected BMM block!"
    else
        echo
        echo "ERROR sidechain did not connect BMM block!"
        CURRENT_SIDE_BLOCKS=$(( CURRENT_SIDE_BLOCKS - 1 ))
    fi

    ((COUNTER++))
done


# Check that the deposit has been added to our sidechain balance
BALANCE=`./sidechains/src/testchain-cli --regtest getbalance`
BC=`echo "$BALANCE>0.9" | bc`
if [ $BC -eq 1 ]; then
    echo
    echo "Sidechain balance updated, deposit matured!"
    echo "Sidechain balance: $BALANCE"
else
    echo
    echo "ERROR sidechain balance not what it should be... Balance: $BALANCE!"
    exit
fi


# Test sending the deposit around to other addresses on the sidechain
# TODO




# Shutdown DriveNet, restart it, and make sure nothing broke
REINDEX=1
restartdrivenet




#
# Withdraw from the sidechain
#

# Get a mainchain address
MAINCHAIN_ADDRESS=`./mainchain/src/drivenet-cli --regtest getnewaddress mainchain legacy`
REFUND_ADDRESS=`./sidechains/src/testchain-cli --regtest getnewaddress refund legacy`

# Call the CreateWithdrawal RPC
echo
echo "We will now create a withdrawal on the sidechain"
./sidechains/src/testchain-cli --regtest createwithdrawal $MAINCHAIN_ADDRESS $REFUND_ADDRESS 0.5 0.1 0.1
sleep 3s

# Mine enough BMM blocks for a withdrawal bundle to be created and sent to the
# mainchain. We will mine up to 300 blocks before giving up.
echo
echo "Now we will mine enough BMM blocks for the sidechain to create a bundle"
COUNTER=1
while [ $COUNTER -le 300 ]
do
    # Wait a little bit
    echo
    echo "Waiting for new BMM request to make it to the mainchain..."
    sleep 0.26s

    echo "Mining mainchain block"
    # Generate mainchain block
    ./mainchain/src/drivenet-cli --regtest generate 1

    CURRENT_BLOCKS=$(( CURRENT_BLOCKS + 1 ))

    # Check that mainchain block was connected
    GETINFO=`./mainchain/src/drivenet-cli --regtest getmininginfo`
    COUNT=`echo $GETINFO | grep -c "\"blocks\": $CURRENT_BLOCKS"`
    if [ "$COUNT" -eq 1 ]; then
        echo
        echo "Mainchain has $CURRENT_BLOCKS blocks"
    else
        echo
        echo "ERROR failed to mine block for bundle creation!"
        exit
    fi

    # Refresh BMM on the sidechain
    echo
    echo "Refreshing BMM on the sidechain..."
    ./sidechains/src/testchain-cli --regtest refreshbmm $BMMAMOUNT

    CURRENT_SIDE_BLOCKS=$(( CURRENT_SIDE_BLOCKS + 1 ))

    # Check that BMM block was added to the side chain
    GETINFO=`./sidechains/src/testchain-cli --regtest getmininginfo`
    COUNT=`echo $GETINFO | grep -c "\"blocks\": $CURRENT_SIDE_BLOCKS"`
    if [ "$COUNT" -eq 1 ]; then
        echo
        echo "Sidechain connected BMM block!"
    else
        echo
        echo "ERROR sidechain did not connect BMM block!"
        CURRENT_SIDE_BLOCKS=$(( CURRENT_SIDE_BLOCKS - 1 ))
    fi

    # Check for bundle
    BUNDLECHECK=`./mainchain/src/drivenet-cli --regtest listwithdrawalstatus 0`
    if [ "-$BUNDLECHECK-" != "--" ]; then
        echo "Bundle has been found!"
        break
    fi

    ((COUNTER++))
done

# Check if bundle was created
HASHBUNDLE=`./mainchain/src/drivenet-cli --regtest listwithdrawalstatus 0`
HASHBUNDLE=`echo $HASHBUNDLE | python -c 'import json, sys; obj=json.load(sys.stdin); print obj[0]["hash"]'`
if [ -z "$HASHBUNDLE" ]; then
    echo "Error: No withdrawal bundle found"
    exit
else
    echo "Good: bundle found: $HASHBUNDLE"
fi

# Check that bundle has work score
WORKSCORE=`./mainchain/src/drivenet-cli --regtest getworkscore 0 $HASHBUNDLE`
if [ $WORKSCORE -lt 1 ]; then
    echo "Error: No Workscore!"
    exit
else
    echo "Good: workscore: $WORKSCORE"
fi

# Check that if we replace the tip the workscore does not change
replacetip
NEWWORKSCORE=`./mainchain/src/drivenet-cli --regtest getworkscore 0 $HASHBUNDLE`
if [ $NEWWORKSCORE -ne $WORKSCORE ]; then
    echo "Error: Workscore invalid after replacing tip!"
    echo "$NEWWORKSCORE != $WORKSCORE"
    exit
else
    echo "Good - Workscore: $NEWWORKSCORE unchanged"
fi

# Mine blocks until payout should happen
BLOCKSREMAINING=`./mainchain/src/drivenet-cli --regtest listwithdrawalstatus 0`
BLOCKSREMAINING=`echo $BLOCKSREMAINING | python -c 'import json, sys; obj=json.load(sys.stdin); print obj[0]["nblocksleft"]'`
WORKSCORE=`./mainchain/src/drivenet-cli --regtest getworkscore 0 $HASHBUNDLE`

echo
echo "Blocks remaining in verification period: $BLOCKSREMAINING"
echo "Workscore: $WORKSCORE / $MINWORKSCORE"
sleep 10s

echo "Will now mine $MINWORKSCORE blocks"
./mainchain/src/drivenet-cli --regtest generate $MINWORKSCORE


# Check if balance of mainchain address received payout
WITHDRAW_BALANCE=`./mainchain/src/drivenet-cli --regtest getbalance mainchain`
BC=`echo "$WITHDRAW_BALANCE>0.4" | bc`
if [ $BC -eq 1 ]; then
    echo
    echo
    echo -e "\e[32m==========================\e[0m"
    echo
    echo -e "\e[1mpayout received!\e[0m"
    echo "amount: $WITHDRAW_BALANCE"
    echo
    echo -e "\e[32m==========================\e[0m"
else
    echo
    echo -e "\e[31mError: payout not received!\e[0m"
    exit
fi

# Shutdown DriveNet, restart it, and make sure nothing broke
REINDEX=0
restartdrivenet

# Restart again but with reindex
REINDEX=1
restartdrivenet

echo
echo
echo -e "\e[32mDriveNet integration testing completed!\e[0m"
echo
echo "Make sure to backup log files you want to keep before running again!"
echo
echo -e "\e[32mIf you made it here that means everything probably worked!\e[0m"
echo "If you notice any issues but the script still made it to the end, please"
echo "open an issue on GitHub!"

if [ $SKIP_SHUTDOWN -ne 1 ]; then
    # Stop the binaries
    echo
    echo
    echo "Will now shut down!"
    ./mainchain/src/drivenet-cli --regtest stop
    ./sidechains/src/testchain-cli --regtest stop
fi
