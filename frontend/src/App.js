import React, { useState, useEffect } from 'react';
import './App.css';
import WalletCard from './components/WalletCard';
import TransactionHistory from './components/TransactionHistory';
import AddFundsModal from './components/AddFundsModal';
import SendMoneyModal from './components/SendMoneyModal';
import { getBalance, getTransactions, getPaymentConfig, addFunds, sendMoney } from './services/api';

function App() {
  const [balance, setBalance] = useState(0);
  const [transactions, setTransactions] = useState([]);
  const [paymentConfig, setPaymentConfig] = useState(null);
  const [showAddFundsModal, setShowAddFundsModal] = useState(false);
  const [showSendMoneyModal, setShowSendMoneyModal] = useState(false);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    loadData();

    const intervalId = setInterval(() => {
      loadData();
    }, 2000);

    return () => clearInterval(intervalId);
  }, []);

  const loadData = async () => {
    try {
      const [balanceData, transactionsData, paymentConfigData] = await Promise.all([
        getBalance(),
        getTransactions(),
        getPaymentConfig()
      ]);
      setBalance(balanceData.balance);
      setTransactions(transactionsData);
      setPaymentConfig(paymentConfigData);
    } catch (error) {
      console.error('Error loading data:', error);
    } finally {
      setLoading(false);
    }
  };

  const handleAddFunds = async (amount, description) => {
    try {
      const response = await addFunds(amount, description);
      setBalance(response.balance);
      await loadData();
      setShowAddFundsModal(false);
    } catch (error) {
      console.error('Error adding funds:', error);
      alert('Failed to add funds. Please try again.');
    }
  };

  const handleSendMoney = async (amount, description) => {
    try {
      if (!paymentConfig?.merchantId) {
        alert('Payment configuration is unavailable.');
        return;
      }
      const response = await sendMoney(amount, paymentConfig.merchantId, description);
      setBalance(response.balance);
      await loadData();
      setShowSendMoneyModal(false);
    } catch (error) {
      console.error('Error sending money:', error);
      alert(error.response?.data?.error || 'Failed to send money. Please try again.');
    }
  };

  const handleRefresh = () => {
    loadData();
  };

  if (loading) {
    return <div className="loading">Loading...</div>;
  }

  return (
    <div className="app">
      <header className="header">
        <h1>Digital Wallet</h1>
        <p className="subtitle">Manage your funds easily</p>
      </header>

      <WalletCard
        balance={balance}
        onAddFunds={() => setShowAddFundsModal(true)}
        onSendMoney={() => setShowSendMoneyModal(true)}
        onRefresh={handleRefresh}
      />

      <TransactionHistory transactions={transactions} />

      {showAddFundsModal && (
        <AddFundsModal
          onClose={() => setShowAddFundsModal(false)}
          onAddFunds={handleAddFunds}
        />
      )}

      {showSendMoneyModal && (
        <SendMoneyModal
          balance={balance}
          paymentConfig={paymentConfig}
          onClose={() => setShowSendMoneyModal(false)}
          onSendMoney={handleSendMoney}
        />
      )}
    </div>
  );
}

export default App;
