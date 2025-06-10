# app.py
# Streamlit app for forecasting Apple stock prices using the pre-trained LSTM model.

import streamlit as st
import pandas as pd
import numpy as np
import plotly.express as px
import plotly.graph_objects as go
from tensorflow.keras.models import load_model
import joblib
from datetime import timedelta

# Streamlit app configuration
st.set_page_config(page_title="Apple Stock Price Forecaster", layout="wide")

# Title
st.title("Apple Stock Price Forecasting App")
st.markdown("Select a date range to view historical stock prices and get a 30-day forecast for Apple's stock price using the LSTM model.")

# Load data
@st.cache_data
def load_data():
    df = pd.read_csv("AAPL.csv")  # Adjust path as needed
    df['Date'] = pd.to_datetime(df['Date'], format='%d-%m-%Y')
    df.set_index('Date', inplace=True)
    return df[['Close']]

df = load_data()

# Date range selector
st.subheader("Select Date Range for Historical Data")
col1, col2 = st.columns(2)
with col1:
    start_date = st.date_input("Start Date", min_value=df.index.min(), max_value=df.index.max(), value=df.index.min())
with col2:
    end_date = st.date_input("End Date", min_value=df.index.min(), max_value=df.index.max(), value=df.index.max())

# Filter data based on date range
filtered_df = df.loc[start_date:end_date]

# Display historical data
st.subheader("Historical Stock Prices")
fig = px.line(filtered_df, x=filtered_df.index, y='Close', title='Historical Apple Stock Prices')
st.plotly_chart(fig, use_container_width=True)

# Load LSTM model and scaler
@st.cache_resource
def load_lstm_model_and_scaler():
    model = load_model('lstm_model.h5')
    scaler = joblib.load('scaler.pkl')
    return model, scaler

# Forecast button
if st.button("Generate 30-Day Forecast"):
    st.subheader("30-Day Stock Price Forecast")
    model, scaler = load_lstm_model_and_scaler()
    
    # Prepare data for LSTM forecast
    seq_len = 60
    last_sequence = scaler.transform(filtered_df[['Close']].tail(seq_len).values)
    lstm_predictions = []
    
    # Generate 30-day forecast
    current_sequence = last_sequence.copy()
    for _ in range(30):
        input_seq = current_sequence.reshape(1, seq_len, 1)
        pred = model.predict(input_seq, verbose=0)[0][0]
        lstm_predictions.append(pred)
        current_sequence = np.append(current_sequence[1:], [[pred]], axis=0)
    
    # Inverse transform predictions
    lstm_forecast = scaler.inverse_transform(np.array(lstm_predictions).reshape(-1, 1)).flatten()
    future_dates = pd.date_range(filtered_df.index.max() + timedelta(days=1), periods=30)
    forecast_df = pd.DataFrame({'Date': future_dates, 'Predicted Close': lstm_forecast})
    
    # Plot historical and forecast
    fig = go.Figure()
    fig.add_trace(go.Scatter(x=filtered_df.index, y=filtered_df['Close'], mode='lines', name='Historical', line=dict(color='blue')))
    fig.add_trace(go.Scatter(x=forecast_df['Date'], y=forecast_df['Predicted Close'], mode='lines', name='Forecast', line=dict(color='red')))
    fig.update_layout(title="Apple Stock Price: Historical and 30-Day Forecast", xaxis_title="Date", yaxis_title="Close Price", template="plotly_white")
    st.plotly_chart(fig, use_container_width=True)
    
    # Display forecast data
    st.subheader("Forecasted Prices")
    st.dataframe(forecast_df[['Date', 'Predicted Close']].style.format({"Predicted Close": "{:.2f}"}))