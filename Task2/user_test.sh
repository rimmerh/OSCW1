# Create test users (as root)
sudo useradd testuser1
sudo useradd testuser2
sudo useradd testuser3

# Run processes as different users
sudo -u testuser1 ./cpu_spam &
sudo -u testuser2 ./cpu_spam &
sudo -u testuser3 ./cpu_spam &
sudo -u testuser1 ./cpu_spam &  # Second process for testuser1

# Run your monitor
./monitor.exe 10

# Clean up
sudo pkill -f cpu_spam
sudo userdel testuser1
sudo userdel testuser2
sudo userdel testuser3
